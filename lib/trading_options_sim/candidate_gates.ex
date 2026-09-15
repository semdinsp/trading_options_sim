defmodule TradingOptionsSim.CandidateGates do
  @moduledoc """
  A pure, mostly DB-free classification of one
  `Sim.full_universe_version_metrics/0` row against nine promotion
  gates — ported from `trading_system`'s own `CandidateGates` (confirmed
  by reading that module directly), same nine letters (N/S/E/D/X/C/R/G/T),
  same thresholds except where this app's data model genuinely differs
  (see each private gate function's own comment).

  **Display-only, advisory — this module never blocks a real
  promotion.** Same posture the source module documents: "Ranking among
  candidates happens elsewhere... this module only classifies, never
  sorts or scores." `Sim.promote_strategy_version/2` (the actual
  state-mutating function) has no reference to this module at all —
  gates exist purely to help an operator triage the `/candidates` page,
  the same way they exist purely for triage in `trading_system`.

  `evaluate/2`'s own gate order — every letter, in this order, forms the
  `Gates` column strip:
  """

  alias TradingOptionsSim.Sim

  @gate_order [
    :sample_floor,
    :statistical,
    :economic,
    :dollars_agree,
    :exit_logic,
    :churn,
    :recency,
    :regime_concentration,
    :quarantine_tenure
  ]

  @gate_letters %{
    sample_floor: "N",
    statistical: "S",
    economic: "E",
    dollars_agree: "D",
    exit_logic: "X",
    churn: "C",
    recency: "R",
    regime_concentration: "G",
    quarantine_tenure: "T"
  }

  @sample_floor 30
  @exit_bucket_dominance_threshold Decimal.new("0.70")
  @churn_exclusion_ratio_threshold Decimal.new("0.20")
  @recency_day_limit 3
  @regime_concentration_sample_floor 30
  @regime_concentration_dominance_threshold Decimal.new("0.50")
  @quarantine_tenure_days 20

  @type verdict :: :pass | :fail | :not_computed | :not_applicable

  @spec gate_order() :: [atom()]
  def gate_order, do: @gate_order

  @spec gate_letter(atom()) :: String.t()
  def gate_letter(gate), do: Map.fetch!(@gate_letters, gate)

  @doc "Every gate's verdict for `row`, as `%{gate_atom => verdict}` — see each private gate function for its own threshold/reasoning."
  @spec evaluate(map(), DateTime.t()) :: %{atom() => verdict()}
  def evaluate(row, now \\ DateTime.utc_now()) do
    %{
      sample_floor: sample_floor(row),
      statistical: statistical(row),
      economic: economic(row),
      dollars_agree: dollars_agree(row),
      exit_logic: exit_logic(row),
      churn: churn(row),
      recency: recency(row, now),
      regime_concentration: regime_concentration(row),
      quarantine_tenure: quarantine_tenure(row)
    }
  end

  @doc "True only if every computed gate (excluding `:not_computed`/`:not_applicable`) is `:pass`."
  @spec candidate?(%{atom() => verdict()}) :: boolean()
  def candidate?(gates) do
    gates
    |> Map.values()
    |> Enum.reject(&(&1 in [:not_computed, :not_applicable]))
    |> Enum.all?(&(&1 == :pass))
  end

  @doc "True if `:quarantine_tenure` is the only failing gate — surfaced as a 'tenure-only' badge, a version that's otherwise ready and just needs more days in quarantine."
  @spec blocked_only_by_tenure?(%{atom() => verdict()}) :: boolean()
  def blocked_only_by_tenure?(gates) do
    {tenure, rest} = Map.pop(gates, :quarantine_tenure)

    tenure == :fail and
      rest
      |> Map.values()
      |> Enum.reject(&(&1 in [:not_computed, :not_applicable]))
      |> Enum.all?(&(&1 == :pass))
  end

  @doc "Count of `:fail` verdicts, excluding `:not_computed`/`:not_applicable` — the page's default sort-ascending 'near-miss' signal."
  @spec gates_failed(%{atom() => verdict()}) :: non_neg_integer()
  def gates_failed(gates) do
    gates |> Map.values() |> Enum.count(&(&1 == :fail))
  end

  # Gate N — at least 30 closed (non-churn) trades. Below this, every
  # other statistic is too noisy to act on.
  defp sample_floor(%{n_closes: n}) when is_integer(n) and n >= @sample_floor, do: :pass
  defp sample_floor(_row), do: :fail

  # Gate S — the one-sided 95% lower confidence bound on expectancy_r
  # itself clears zero, not just the point estimate. This is the gate
  # `lcb95`-descending sort exists to surface first.
  defp statistical(%{lcb95: lcb95}) when is_float(lcb95) and lcb95 > 0, do: :pass
  defp statistical(_row), do: :fail

  # Gate E — expectancy_r still clears estimated round-trip commission
  # cost, expressed in the same R-units (see Sim.cost_margin/3's own
  # comment on why this uses real per-fill commission instead of
  # trading_system's required_r/slippage-estimate fallback).
  defp economic(%{cost_margin: %Decimal{} = cost_margin}) do
    if Decimal.compare(cost_margin, 0) == :gt, do: :pass, else: :fail
  end

  defp economic(_row), do: :fail

  # Gate D — the raw dollar total agrees with the R-multiple statistics
  # pointing the same direction (a real profit, net of commission,
  # excluding churn) — catches a case where expectancy_r looks fine but
  # actual realized dollars don't (e.g. skewed by risk_at_entry sizing).
  defp dollars_agree(%{realized_pnl: %Decimal{} = pnl}) do
    if Decimal.compare(pnl, 0) == :gt, do: :pass, else: :fail
  end

  defp dollars_agree(_row), do: :fail

  # Gate X — no single exit-reason bucket dominates (>=70% of exits).
  # e.g. if "eod" (forced expiry-window close, not a rule-triggered
  # exit) is 90% of exits, the exit RULE itself is barely doing
  # anything — the strategy is really "hold until forced out."
  defp exit_logic(%{exit_reason_histogram: histogram}) when map_size(histogram) > 0 do
    total = histogram |> Map.values() |> Enum.sum()

    if total == 0 do
      :fail
    else
      max_bucket = histogram |> Map.values() |> Enum.max()
      ratio = Decimal.div(Decimal.new(max_bucket), Decimal.new(total))
      if Decimal.compare(ratio, @exit_bucket_dominance_threshold) == :lt, do: :pass, else: :fail
    end
  end

  defp exit_logic(_row), do: :fail

  # Gate C — excluded (churn) runs are under 20% of the version's total
  # run count. A high ratio means the "real" trade count/expectancy
  # above is measuring a flatten-and-reopen loop, not genuine signal.
  defp churn(%{n_closes: n_closes, excluded_count: excluded_count}) do
    total = (n_closes || 0) + (excluded_count || 0)

    if total == 0 do
      :fail
    else
      ratio = Decimal.div(Decimal.new(excluded_count || 0), Decimal.new(total))
      if Decimal.compare(ratio, @churn_exclusion_ratio_threshold) == :lt, do: :pass, else: :fail
    end
  end

  # Gate R — traded within the last 3 calendar days. A version that
  # hasn't fired in a while may no longer match current market
  # conditions even if its historical stats still look good.
  defp recency(%{last_traded_on: %DateTime{} = last_traded_on}, %DateTime{} = now) do
    if DateTime.diff(now, last_traded_on, :day) <= @recency_day_limit, do: :pass, else: :fail
  end

  defp recency(_row, _now), do: :fail

  # Gate G — a referral, not a rejection (same as the source module): a
  # version whose own entry rule doesn't already condition on regime is
  # :not_applicable if it's below the regime sample floor (not enough
  # per-regime data to say anything), :fail if one regime bucket
  # dominates the signed R contribution (this version's edge may really
  # be "works in regime X," not a general edge — a candidate to FORK
  # with an explicit regime filter, not to reject outright), :pass
  # otherwise. A version whose rules already declare a regime condition
  # is :not_applicable — it's already regime-scoped by construction.
  defp regime_concentration(%{rules: rules, strategy_version_id: version_id})
       when is_map(rules) do
    if TradingCore.RuleEngine.regime_condition?(rules["entry"]) do
      :not_applicable
    else
      regime_concentration_from_buckets(version_id)
    end
  end

  defp regime_concentration(_row), do: :not_computed

  defp regime_concentration_from_buckets(version_id) do
    buckets =
      %TradingOptionsSim.Sim.StrategyVersion{id: version_id}
      |> Sim.closed_runs_by_regime()
      |> Enum.map(fn {_label, runs} -> bucket_stats(runs) end)

    total_n = buckets |> Enum.map(& &1.n) |> Enum.sum()

    cond do
      total_n < @regime_concentration_sample_floor ->
        :not_computed

      true ->
        total_contribution = buckets |> Enum.map(& &1.contribution) |> Enum.sum()

        if total_contribution == 0.0 do
          :not_computed
        else
          dominant? =
            Enum.any?(buckets, fn bucket ->
              ratio = abs(bucket.contribution / total_contribution)
              ratio > Decimal.to_float(@regime_concentration_dominance_threshold)
            end)

          if dominant?, do: :fail, else: :pass
        end
    end
  end

  # n * mean(realized_pnl_net) for one regime bucket — its signed
  # contribution to the version's overall total, dollar-denominated
  # (not R-multiples: closed_runs_by_regime/1 doesn't carry
  # risk_at_entry, and dollars are enough to detect dominance here).
  defp bucket_stats(runs) do
    pnls = runs |> Enum.map(& &1.realized_pnl_net) |> Enum.reject(&is_nil/1)
    n = length(pnls)

    contribution =
      if n == 0,
        do: 0.0,
        else: pnls |> Enum.reduce(Decimal.new(0), &Decimal.add/2) |> Decimal.to_float()

    %{n: n, contribution: contribution}
  end

  # Gate T — the "house rule": at least 20 TRADING days in quarantine
  # before promotion, regardless of how good the stats look. Fails (not
  # :not_applicable) for a discovery-stage row too — no evidence yet
  # reads as "not a candidate yet," not "exempt from this gate."
  defp quarantine_tenure(%{quarantine_trading_days: days})
       when is_integer(days) and days >= @quarantine_tenure_days,
       do: :pass

  defp quarantine_tenure(_row), do: :fail
end
