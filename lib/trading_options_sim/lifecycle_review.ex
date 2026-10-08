defmodule TradingOptionsSim.LifecycleReview do
  @moduledoc """
  Automatic clean-up of losing strategy versions, with a regime rescue.
  Runs after the 07:00 UTC quarantine job (`QuarantineEligibilityWorker`).

  A version is a LOSER when it is:
    * an active `discovery` version with at least #{30} closed trades
      over at least #{3} sessions and negative net P&L (commissions in), or
    * a `quarantine` version that fails the quarantine test
      (`Sim.quarantine_failing?/1`) after #{20}+ quarantine trading days.

  Before switching a loser off, its trades are split by the trend x vol
  regime recorded at entry (`Sim.best_regime_cell/1`). If one regime
  cell has been profitable (>= 15 trades, >= 2 sessions, positive net
  P&L), its edge is kept: it is FORKED with an entry gate on that regime
  (`regime_trend_ordinal == t AND regime_vol_ordinal == v`) and the fork
  is activated in discovery. The losing parent is then RETIRED (monitors
  stopped, `lifecycle_stage: "retired"`, `retired_reason:
  "lifecycle_review"`), with or without a fork. A quarantine loser with no
  profitable regime is retired by `Sim`'s job 3 instead.

  Retired rather than deactivated since 2026-10-08 (user decision): a
  deactivated loser stayed on /candidates and in the leaderboards though
  nobody would revisit it. Retirement keeps every run and is reversible
  (unretire, then activate).

  Never touched: versions linked to trading_live or in `test_portfolio`,
  always-long controls (the baselines), and the `Noise-Baseline` and
  `od:slope-hold` sets the user asked to keep. Nothing is deleted.

  Mode: `:dry_run` (report only) or `:apply`, from
  `config :trading_options_sim, :lifecycle_review_mode`. Defaults to
  `:dry_run`, so the actions can be reviewed before anything changes.
  """

  require Logger
  import Ecto.Query

  alias TradingOptionsSim.{Repo, Sim, SimActivator}
  alias TradingOptionsSim.Sim.{SimRun, Strategy, StrategyVersion}

  @min_trades 30
  @min_sessions 3
  @protected_tags ~w(Noise-Baseline od:slope-hold)
  @default_risk_controls %{
    "method" => "percent_of_entry",
    "stop_loss_percent" => 10,
    "take_profit_percent" => 20
  }
  @trend_names %{-1 => "down", 0 => "chop", 1 => "up"}
  @vol_names %{-1 => "calm", 0 => "normal", 1 => "stressed"}

  @doc """
  Reviews every loser and returns the planned (or taken) actions:
  `[%{version_id, name, stage, action, cell, stats}]`, where `action` is
  `:fork_and_retire`, `:retire`, or (dry run) the same atom
  marked as not applied. `opts[:mode]` overrides the configured mode.
  """
  @spec run(keyword()) :: [map()]
  def run(opts \\ []) do
    mode =
      Keyword.get(
        opts,
        :mode,
        Application.get_env(:trading_options_sim, :lifecycle_review_mode, :dry_run)
      )

    actions = Enum.map(losers(), &plan/1)

    if mode == :apply, do: Enum.each(actions, &apply_action/1)

    Logger.info(
      "LifecycleReview (#{mode}): #{Enum.count(actions, &(&1.action == :fork_and_retire))} regime forks, " <>
        "#{length(actions)} retirements"
    )

    Enum.map(actions, &Map.put(&1, :applied, mode == :apply))
  end

  @doc "The regime gate a fork for `cell` adds to its entry rule."
  @spec regime_gate(map()) :: map()
  def regime_gate(%{trend: t, vol: v}) do
    %{
      "all" => [
        %{"signal" => "regime_trend_ordinal", "op" => "eq", "value" => t},
        %{"signal" => "regime_vol_ordinal", "op" => "eq", "value" => v}
      ]
    }
  end

  defp losers do
    candidates =
      Repo.all(
        from v in StrategyVersion,
          join: s in assoc(v, :strategy),
          left_join: t in assoc(v, :tags),
          where: is_nil(v.deleted_at) and not is_nil(v.activated_at) and is_nil(v.deactivated_at),
          where: v.lifecycle_stage in ["discovery", "quarantine"] and is_nil(v.live_strategy_id),
          where: not ilike(s.name, "%Control%"),
          group_by: [v.id, s.name],
          having:
            fragment("NOT (array_agg(?) && ?)", t.name, type(^@protected_tags, {:array, :string})),
          select: {v, s.name}
      )

    stats = trade_stats(Enum.map(candidates, fn {v, _} -> v.id end))

    Enum.filter(candidates, fn {v, _name} ->
      case v.lifecycle_stage do
        "discovery" ->
          case stats[v.id] do
            %{n: n, sessions: s, net: net} ->
              n >= @min_trades and s >= @min_sessions and Decimal.compare(net, 0) == :lt

            _ ->
              false
          end

        "quarantine" ->
          v.quarantine_trading_days >= 20 and Sim.quarantine_failing?(v.id) and
            Sim.best_regime_cell(v.id) != nil
      end
    end)
    |> Enum.map(fn {v, name} -> {v, name, stats[v.id]} end)
  end

  defp plan({version, name, stats}) do
    cell = Sim.best_regime_cell(version.id)

    action =
      if cell != nil and not regime_gated?(version), do: :fork_and_retire, else: :retire

    %{
      version_id: version.id,
      name: name,
      stage: version.lifecycle_stage,
      action: action,
      cell: cell,
      stats: stats,
      version: version
    }
  end

  defp apply_action(%{action: :fork_and_retire} = a) do
    fork_with_gate(a.version, a.name, a.cell, a.stats)
    retire(a.version)
  end

  defp apply_action(%{action: :retire} = a), do: retire(a.version)

  # Stop the monitors first (flattening any open position), then retire:
  # downgrade_strategy_version/3 only changes the stage.
  defp retire(version) do
    {:ok, _count} = SimActivator.deactivate(Sim.get_strategy_version!(version.id))

    case Sim.downgrade_strategy_version(
           Sim.get_strategy_version!(version.id),
           "retired",
           "lifecycle_review"
         ) do
      {:ok, _} ->
        :ok

      error ->
        Logger.error("LifecycleReview: retire #{version.id} failed: #{inspect(error)}")
    end
  rescue
    error ->
      Logger.error("LifecycleReview: retire #{version.id} failed: #{Exception.message(error)}")
  end

  defp fork_with_gate(parent, parent_name, cell, stats) do
    label = "#{@trend_names[cell.trend]}/#{@vol_names[cell.vol]}"
    name = "#{parent_name} [Regime: #{label}]"

    if Repo.exists?(from s in Strategy, where: s.name == ^name) do
      Logger.info("LifecycleReview: #{name} already exists; not forking again")
    else
      params = parent.params || %{}

      params =
        if Map.has_key?(params, "risk_controls") or Map.has_key?(params, "exit_strategy"),
          do: params,
          else: Map.put(params, "risk_controls", @default_risk_controls)

      entry = %{"all" => [Map.get(parent.rules, "entry", %{}), regime_gate(cell)]}

      notes =
        "Regime-gated fork of #{parent.id} (#{parent_name}), created automatically by LifecycleReview. " <>
          "The parent was losing overall (#{describe(stats)}) but profitable in #{label} " <>
          "(#{cell.n} trades over #{cell.sessions} sessions, net $#{Decimal.round(cell.net, 2)}, " <>
          "$#{Decimal.round(cell.per_trade, 2)}/trade), so this fork trades only when regime_trend_ordinal == #{cell.trend} " <>
          "and regime_vol_ordinal == #{cell.vol}. The parent was retired. In-sample selection on a regime split: " <>
          "treat as a hypothesis until it holds up out of sample."

      with {:ok, s} <- Sim.create_strategy(%{name: name, notes: notes}),
           {:ok, v} <-
             Sim.create_strategy_version(s, %{
               version: 1,
               parent_version_id: parent.id,
               generation: (parent.generation || 1) + 1,
               rules: Map.put(parent.rules, "entry", entry),
               params: params,
               option_leg_config: parent.option_leg_config,
               position_sizing: parent.position_sizing,
               direction: parent.direction,
               target_pool_id: parent.target_pool_id
             }),
           {:ok, v} <- Sim.set_strategy_version_notes(v, notes) do
        for tag <- ["Regime-Gated-Fork", "regime:#{label}"],
            do: Sim.add_tag_to_strategy_version_by_name(v, tag)

        SimActivator.activate(v)
        Logger.info("LifecycleReview: forked #{name} (#{v.id})")
      else
        error -> Logger.error("LifecycleReview: fork of #{parent.id} failed: #{inspect(error)}")
      end
    end
  end

  # Already gated on regime: forking it again would only nest gates.
  defp regime_gated?(%StrategyVersion{rules: rules}) do
    rules |> Map.get("entry", %{}) |> Jason.encode!() |> String.contains?("regime_trend_ordinal")
  end

  defp describe(nil), do: "no stats"

  defp describe(%{n: n, sessions: s, net: net}),
    do: "#{n} trades over #{s} sessions, net $#{Decimal.round(net, 2)}"

  # %{version_id => %{n, sessions, net}} over closed, entered,
  # non-excluded runs; net is commission-inclusive where known.
  defp trade_stats([]), do: %{}

  defp trade_stats(ids) do
    Repo.all(
      from r in SimRun,
        where:
          r.strategy_version_id in ^ids and r.status == "closed" and is_nil(r.excluded_reason),
        where: not is_nil(r.entry_at),
        group_by: r.strategy_version_id,
        select:
          {r.strategy_version_id,
           %{
             n: count(r.id),
             sessions: count(fragment("DISTINCT (?)::date", r.exit_at)),
             net: sum(coalesce(r.realized_pnl_net, r.realized_pnl))
           }}
    )
    |> Map.new()
  end
end
