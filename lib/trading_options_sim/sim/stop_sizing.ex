defmodule TradingOptionsSim.Sim.StopSizing do
  @moduledoc """
  Stop sizing from the stop ladder (`TradingOptionsSim.StopLadder`,
  `sim_run_stop_ladder`): for one version, what each virtual stop would
  have returned on the version's own trades, paired by session against
  the version's real risk controls. Read-only. Backs the `stop_sizing`,
  `stop_sizing_all` and `stop_ab_report` MCP tools.

  ## Population

  The version's scored runs (closed, with an R, not churn, not excluded;
  as `Sim.list_candidate_metrics/0`) entered on or after `since`, that
  have a COMPLETE ladder: all 18 premium rows, both time rows, and either
  all 8 underlying rows or none (no daily ATR at entry). A ladder is left
  incomplete when its monitor restarts or is deactivated before every
  rung closes; such runs, and runs from before the ladder, are counted in
  `caveats` and left out of every number, so each rung and the real
  controls are compared over exactly the same trades.

  ## Statistics

  R = net P&L / premium at risk, the `Sim` basis. A session is the New
  York date of the run's entry; a session's R is the sum of its runs' R.
  `lcb90_session` is the one-sided 90% lower bound (z = 1.2816) on the
  mean session R, null under 2 sessions. `delta_vs_actual_lcb90` is the
  same bound on the per-session difference (rung - real controls). All
  of it is in-sample.
  """

  import Ecto.Query

  alias TradingOptionsSim.Repo
  alias TradingOptionsSim.Sim.{SimFill, SimRun, SimRunStopLadder, StrategyVersion}

  @z90 1.2816
  @stages ~w(discovery quarantine test_portfolio retired)
  @stop_ab_tag "Stop-AB-2026-11-27"

  @doc """
  The sizing report for one version. `opts`: `:with_tp` (default true),
  `:since` (Date or DateTime, default all), `:min_sessions` (default 10).
  `{:error, :not_found}` for an unknown id.
  """
  def stop_sizing(version_id, opts \\ []) do
    case Repo.get(StrategyVersion, version_id) do
      nil -> {:error, :not_found}
      version -> {:ok, report(version, opts)}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc """
  One summary row per version (optionally one `stage`) with at least one
  ladder row: run and session counts, the real controls' lcb90_session,
  the best rung by lcb90_session, and the suggestion (or why not).
  """
  def stop_sizing_all(opts \\ []) do
    stage = Keyword.get(opts, :stage)

    if stage && stage not in @stages do
      {:error, :invalid_stage}
    else
      ids =
        from(l in SimRunStopLadder,
          join: v in StrategyVersion,
          on: v.id == l.strategy_version_id,
          where: is_nil(v.deleted_at),
          distinct: true,
          select: l.strategy_version_id
        )
        |> then(fn q -> if stage, do: where(q, [_l, v], v.lifecycle_stage == ^stage), else: q end)
        |> Repo.all()

      rows =
        from(v in StrategyVersion, where: v.id in ^ids, preload: :strategy)
        |> Repo.all()
        |> Enum.map(fn version -> summary(report(version, opts), version) end)
        |> Enum.sort_by(& &1.n_runs, :desc)

      {:ok, rows}
    end
  end

  @doc """
  The Stop-AB-2026-11-27 arms side by side: per arm its realised
  per-session R over the sessions every arm traded, the paired
  difference against arm A, stop-fire rate, worst run R, quote fill
  share, and its own ladder (with and without the target).
  """
  def stop_ab_report(opts \\ []) do
    arms =
      from(v in StrategyVersion,
        join: t in assoc(v, :tags),
        where: t.name == ^@stop_ab_tag and is_nil(v.deleted_at),
        preload: :strategy
      )
      |> Repo.all()
      |> Enum.map(&{arm_letter(&1), &1})
      |> Enum.reject(fn {arm, _v} -> is_nil(arm) end)
      |> Enum.sort()

    realised =
      Map.new(arms, fn {arm, v} -> {arm, v |> scored_runs(opts[:since]) |> by_session()} end)

    common =
      realised
      |> Map.values()
      |> Enum.map(&MapSet.new(Map.keys(&1)))
      |> case do
        [] -> MapSet.new()
        [first | rest] -> Enum.reduce(rest, first, &MapSet.intersection/2)
      end
      |> Enum.sort(Date)

    control = Map.get(realised, "A", %{})

    rows =
      Enum.map(arms, fn {arm, v} ->
        runs = scored_runs(v, opts[:since])
        sessions = Map.get(realised, arm)
        series = Enum.map(common, &Map.get(sessions, &1, 0.0))
        paired = Enum.map(common, &(Map.get(sessions, &1, 0.0) - Map.get(control, &1, 0.0)))
        r = Enum.map(runs, & &1.r)

        %{
          arm: arm,
          version_id: v.id,
          trading_system_version_id: v.source_trading_system_version_id,
          name: v.strategy.name,
          n_runs: length(runs),
          n_sessions_all: map_size(sessions),
          n_common_sessions: length(common),
          mean_session_r: mean(series),
          lcb90_session: lcb90(series),
          paired_vs_a_mean: if(arm == "A", do: nil, else: mean(paired)),
          paired_vs_a_lcb90: if(arm == "A", do: nil, else: lcb90(paired)),
          stop_fire_rate: share(runs, &(&1.exit_reason == "stop_loss")),
          worst_run_r: if(r == [], do: nil, else: Enum.min(r)),
          quote_fill_share: quote_fill_share(Enum.map(runs, & &1.id)),
          ladder_with_tp: report(v, Keyword.put(opts, :with_tp, true)).ladder,
          ladder_no_tp: report(v, Keyword.put(opts, :with_tp, false)).ladder
        }
      end)

    {:ok,
     %{
       tag: @stop_ab_tag,
       first_common_session: List.first(common),
       n_common_sessions: length(common),
       ready: length(common) >= 10,
       arms: rows,
       note:
         "In-sample. An arm beats A only if paired_vs_a_lcb90 > 0, at >= 10 common sessions (the rule in each arm's notes)."
     }}
  end

  # -- report ------------------------------------------------------------

  defp report(version, opts) do
    with_tp = Keyword.get(opts, :with_tp, true)
    min_sessions = Keyword.get(opts, :min_sessions, 10)
    runs = scored_runs(version, opts[:since])
    ladder_rows = ladder_rows(Enum.map(runs, & &1.id))
    {complete_ids, incomplete} = complete_ladders(ladder_rows)
    included = Enum.filter(runs, &MapSet.member?(complete_ids, &1.id))
    session_of = Map.new(included, &{&1.id, &1.session})
    actual = by_session(included)
    actual_series = Map.values(actual)

    rungs =
      ladder_rows
      |> Enum.filter(&(MapSet.member?(complete_ids, &1.sim_run_id) and &1.with_tp == with_tp))
      |> Enum.group_by(&{&1.rung_kind, &1.rung_value})

    ladder =
      rungs
      |> Enum.map(fn {{kind, value}, rows} ->
        rung_stats(kind, value, rows, session_of, actual)
      end)
      |> Enum.sort_by(&rung_order/1)
      |> Enum.map(&Map.merge(&1, ids(version)))

    actual_row =
      Map.merge(ids(version), %{
        rung: "actual",
        n: length(included),
        n_sessions: map_size(actual),
        sum_r: Enum.sum(Enum.map(included, & &1.r)),
        mean_r: mean(Enum.map(included, & &1.r)),
        lcb90_session: lcb90(actual_series)
      })

    %{
      version_id: version.id,
      trading_system_version_id: version.source_trading_system_version_id,
      with_tp: with_tp,
      in_sample: true,
      actual: actual_row,
      ladder: ladder,
      excursion_profile: excursion_profile(ladder_rows, complete_ids, with_tp, version),
      stop_value: shadow_value(included, "stop_loss", version),
      tp_value: shadow_value(included, "take_profit", version),
      suggestion: suggestion(ladder, actual_row, min_sessions),
      caveats: %{
        regime_mix: Enum.frequencies_by(included, &(&1.regime || "uncategorized")),
        pre_ladder_runs: length(runs) - length(included) - incomplete,
        incomplete_ladder_runs: incomplete,
        min_sessions: min_sessions
      }
    }
  end

  defp ids(version),
    do: %{
      version_id: version.id,
      trading_system_version_id: version.source_trading_system_version_id
    }

  defp rung_stats(kind, value, rows, session_of, actual) do
    r = rows |> Enum.map(& &1.r_net) |> Enum.reject(&is_nil/1)

    sessions =
      Enum.reduce(rows, %{}, fn row, acc ->
        Map.update(acc, session_of[row.sim_run_id], row.r_net || 0.0, &(&1 + (row.r_net || 0.0)))
      end)

    paired = Enum.map(sessions, fn {d, rr} -> rr - Map.get(actual, d, 0.0) end)

    %{
      rung: rung_label(kind, value),
      rung_kind: kind,
      rung_value: value,
      n: length(rows),
      n_sessions: map_size(sessions),
      stop_fire_rate: share(rows, &(&1.exit_reason == "stop")),
      sum_r: Enum.sum(r),
      mean_r: mean(r),
      win_rate: share(r, &(&1 > 0)),
      worst_r: if(r == [], do: nil, else: Enum.min(r)),
      p05_r: percentile(r, 0.05),
      lcb90_session: lcb90(Map.values(sessions)),
      delta_vs_actual_mean: mean(paired),
      delta_vs_actual_lcb90: lcb90(paired)
    }
  end

  @doc false
  def suggestion(ladder, actual, min_sessions) do
    eligible =
      Enum.filter(ladder, fn rung ->
        rung.n_sessions >= min_sessions and is_number(rung.lcb90_session) and
          (is_nil(actual.lcb90_session) or rung.lcb90_session > actual.lcb90_session) and
          is_number(rung.delta_vs_actual_lcb90) and rung.delta_vs_actual_lcb90 > 0 and
          is_number(rung.mean_r) and rung.mean_r > 0
      end)

    case Enum.max_by(eligible, & &1.lcb90_session, fn -> nil end) do
      nil ->
        %{rung: nil, in_sample: true, reason: no_suggestion_reason(ladder, actual, min_sessions)}

      best ->
        %{
          rung: best.rung,
          rung_kind: best.rung_kind,
          rung_value: best.rung_value,
          lcb90_session: best.lcb90_session,
          delta_vs_actual_lcb90: best.delta_vs_actual_lcb90,
          mean_r: best.mean_r,
          in_sample: true,
          reason: nil
        }
    end
  end

  defp no_suggestion_reason([], _actual, _min), do: "no ladder rows yet"

  defp no_suggestion_reason(ladder, actual, min_sessions) do
    cond do
      Enum.all?(ladder, &(&1.n_sessions < min_sessions)) ->
        "fewer than #{min_sessions} sessions on every rung"

      Enum.all?(ladder, &(not is_number(&1.mean_r) or &1.mean_r <= 0)) ->
        "every rung has mean R <= 0"

      true ->
        "no rung beats the real controls' lcb90_session " <>
          "(#{inspect(actual.lcb90_session)}) with a paired-difference lcb90 > 0"
    end
  end

  # MAE of each run on the no-stop rung (the trade's full path), split by
  # whether it ended a winner, and for each premium rung the share of
  # those eventual winners it stopped out.
  defp excursion_profile(rows, complete_ids, with_tp, version) do
    rows =
      Enum.filter(rows, &(MapSet.member?(complete_ids, &1.sim_run_id) and &1.with_tp == with_tp))

    none = Enum.filter(rows, &(&1.rung_kind == "premium" and is_nil(&1.rung_value)))
    winners = none |> Enum.filter(&((&1.r_net || 0.0) > 0)) |> MapSet.new(& &1.sim_run_id)

    mae = fn ids ->
      none |> Enum.filter(&MapSet.member?(ids, &1.sim_run_id)) |> Enum.map(& &1.mae_pct)
    end

    losers = none |> Enum.map(& &1.sim_run_id) |> MapSet.new() |> MapSet.difference(winners)

    cut =
      rows
      |> Enum.filter(&(&1.rung_kind != "premium" or not is_nil(&1.rung_value)))
      |> Enum.group_by(&{&1.rung_kind, &1.rung_value})
      |> Enum.map(fn {{kind, value}, rs} ->
        stopped =
          Enum.count(rs, &(&1.exit_reason == "stop" and MapSet.member?(winners, &1.sim_run_id)))

        %{
          rung: rung_label(kind, value),
          winners_cut_share:
            if(MapSet.size(winners) > 0, do: stopped / MapSet.size(winners), else: nil)
        }
      end)
      |> Enum.sort_by(&rung_order(%{rung: &1.rung}))

    Map.merge(ids(version), %{
      n_winners: MapSet.size(winners),
      n_losers: MapSet.size(losers),
      winners_mae_pct: percentiles(mae.(winners)),
      losers_mae_pct: percentiles(mae.(losers)),
      winners_cut_by_rung: cut
    })
  end

  # For real stop (or target) exits that have a shadow (the no-stop,
  # no-target rung): sum of realised R minus shadow R, and for stops the
  # realised move against the stop's own distance.
  defp shadow_value(runs, reason, version) do
    hits = Enum.filter(runs, &(&1.exit_reason == reason))
    shadowed = Enum.filter(hits, &is_number(&1.shadow_r))

    base =
      Map.merge(ids(version), %{
        n_exits: length(hits),
        n_with_shadow: length(shadowed),
        sum_realised_minus_shadow_r: Enum.sum(Enum.map(shadowed, &(&1.r - &1.shadow_r))),
        mean_realised_minus_shadow_r: mean(Enum.map(shadowed, &(&1.r - &1.shadow_r)))
      })

    if reason == "stop_loss" do
      slips = hits |> Enum.map(& &1.stop_slippage_pct) |> Enum.reject(&is_nil/1)
      Map.merge(base, %{n_slippage: length(slips), mean_stop_slippage_pct: mean(slips)})
    else
      base
    end
  end

  # -- data --------------------------------------------------------------

  defp scored_runs(version, since) do
    SimRun
    |> where([r], r.strategy_version_id == ^version.id and r.status == "closed")
    |> where([r], not is_nil(r.realized_pnl_net) and not is_nil(r.risk_at_entry))
    |> where([r], r.risk_at_entry != 0 and not is_nil(r.entry_at) and not is_nil(r.exit_at))
    |> where([r], not r.is_churn and is_nil(r.excluded_reason))
    |> since(since)
    |> select([r], %{
      id: r.id,
      entry_at: r.entry_at,
      entry_price: r.entry_price,
      exit_price: r.exit_price,
      exit_reason: r.exit_reason,
      direction: r.direction,
      r: fragment("(? / ?)::float", r.realized_pnl_net, r.risk_at_entry),
      context: r.context
    })
    |> Repo.all()
    |> Enum.map(fn run ->
      ctx = run.context || %{}

      %{
        id: run.id,
        session: session(run.entry_at),
        exit_reason: run.exit_reason,
        r: run.r,
        regime: ctx["regime_label"],
        shadow_r: ctx["shadow_r"],
        stop_slippage_pct: stop_slippage_pct(run, ctx["initial_stop_loss_price"])
      }
    end)
  end

  defp since(query, nil), do: query

  defp since(query, %Date{} = date),
    do: since(query, DateTime.new!(date, ~T[00:00:00], "Etc/UTC"))

  defp since(query, %DateTime{} = at), do: where(query, [r], r.entry_at >= ^at)

  # The realised move minus the stop's distance, in % of entry, in the
  # position's favour: -0.6 means the stop filled 0.6% of entry worse than
  # its level. nil when the run has no recorded initial stop.
  defp stop_slippage_pct(%{exit_reason: "stop_loss"} = run, stop) when is_binary(stop) do
    sign = if run.direction == "short", do: -1, else: 1
    entry = Decimal.to_float(run.entry_price)
    exit = Decimal.to_float(run.exit_price)
    level = stop |> Decimal.new() |> Decimal.to_float()

    if entry > 0, do: (exit - level) / entry * 100 * sign
  rescue
    _ -> nil
  end

  defp stop_slippage_pct(_run, _stop), do: nil

  defp ladder_rows([]), do: []

  defp ladder_rows(run_ids) do
    from(l in SimRunStopLadder,
      where: l.sim_run_id in ^run_ids and l.ladder_version == 1,
      select: %{
        sim_run_id: l.sim_run_id,
        rung_kind: l.rung_kind,
        rung_value: l.rung_value,
        with_tp: l.with_tp,
        exit_reason: l.exit_reason,
        r_net: l.r_net,
        mae_pct: l.mae_pct
      }
    )
    |> Repo.all()
  end

  # {complete run ids, count of incomplete ladders}
  defp complete_ladders(rows) do
    by_run = Enum.group_by(rows, & &1.sim_run_id)

    complete =
      for {id, rs} <- by_run,
          count = Enum.frequencies_by(rs, & &1.rung_kind),
          Map.get(count, "premium", 0) == 18 and Map.get(count, "time", 0) == 2 and
            Map.get(count, "underlying", 0) in [0, 8],
          into: MapSet.new(),
          do: id

    {complete, map_size(by_run) - MapSet.size(complete)}
  end

  defp quote_fill_share([]), do: nil

  defp quote_fill_share(run_ids) do
    {quote_fills, fills} =
      from(f in SimFill,
        where: f.sim_run_id in ^run_ids,
        select:
          {fragment("COUNT(*) FILTER (WHERE ?->>'fill_basis' = 'quote')", f.pricing_snapshot),
           count(f.id)}
      )
      |> Repo.one()

    if fills > 0, do: quote_fills / fills, else: nil
  end

  defp by_session(runs) do
    Enum.reduce(runs, %{}, fn run, acc -> Map.update(acc, run.session, run.r, &(&1 + run.r)) end)
  end

  defp session(%DateTime{} = at),
    do: at |> DateTime.shift_zone!("America/New_York") |> DateTime.to_date()

  defp summary(report, version) do
    best =
      Enum.max_by(
        Enum.filter(report.ladder, &is_number(&1.lcb90_session)),
        & &1.lcb90_session,
        fn -> nil end
      )

    Map.merge(ids(version), %{
      name: version.strategy.name,
      stage: version.lifecycle_stage,
      with_tp: report.with_tp,
      n_runs: report.actual.n,
      n_sessions: report.actual.n_sessions,
      actual_lcb90_session: report.actual.lcb90_session,
      best_rung: best && best.rung,
      best_rung_lcb90_session: best && best.lcb90_session,
      suggestion: report.suggestion.rung,
      suggestion_reason: report.suggestion.reason,
      in_sample: true,
      pre_ladder_runs: report.caveats.pre_ladder_runs
    })
  end

  defp arm_letter(%{strategy: %{name: name}}) do
    case Regex.run(~r/\[Stop-AB ([A-D]):/, name) do
      [_, letter] -> letter
      _ -> nil
    end
  end

  # -- stats -------------------------------------------------------------

  defp rung_label("premium", nil), do: "premium:none"
  defp rung_label(kind, value), do: "#{kind}:#{format_value(value)}"

  defp format_value(v) when is_float(v) and v == trunc(v), do: Integer.to_string(trunc(v))
  defp format_value(v), do: to_string(v)

  defp rung_order(%{rung: rung}) do
    case String.split(rung, ":") do
      ["premium", "none"] -> {0, 1.0e9}
      ["premium", v] -> {0, parse(v)}
      ["underlying", v] -> {1, parse(v)}
      ["time", v] -> {2, parse(v)}
      _ -> {3, 0}
    end
  end

  defp parse(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp mean([]), do: nil
  defp mean(xs), do: Enum.sum(xs) / length(xs)

  @doc false
  def lcb90(xs) when length(xs) < 2, do: nil

  def lcb90(xs) do
    m = mean(xs)
    n = length(xs)
    sd = :math.sqrt(Enum.sum(Enum.map(xs, &((&1 - m) * (&1 - m)))) / (n - 1))
    m - @z90 * sd / :math.sqrt(n)
  end

  defp share([], _fun), do: nil
  defp share(xs, fun), do: Enum.count(xs, fun) / length(xs)

  defp percentile([], _p), do: nil

  defp percentile(xs, p) do
    sorted = Enum.sort(xs)
    idx = max(ceil(p * length(sorted)) - 1, 0)
    Enum.at(sorted, idx)
  end

  defp percentiles(xs),
    do: %{
      p25: percentile(xs, 0.25),
      p50: percentile(xs, 0.5),
      p75: percentile(xs, 0.75),
      p90: percentile(xs, 0.9)
    }
end
