defmodule TradingOptionsSimWeb.Api.Serializer do
  @moduledoc """
  Plain-map JSON shapes for `/api/v1` — no separate JSON view modules,
  matching `trading_system`'s own convention for this size of API.
  `Decimal`/`DateTime` values are stringified explicitly since `Jason`
  doesn't encode `Decimal` by default.
  """

  alias TradingOptionsSim.Sim.Caveat

  @doc """
  Parses `"limit"`/`"offset"` query-string params (both optional
  strings, since Plug never coerces query params to integers) into the
  `[limit: _, offset: _]` keyword list `Sim.list_sim_runs_page/2` and
  `list_strategy_versions_page/2` both accept — an unparseable or
  missing value falls back to each function's own default (20/0) rather
  than raising, so a malformed query string just gets the default page
  instead of a 500.
  """
  @spec pagination_opts(map()) :: keyword()
  def pagination_opts(params) do
    [limit: parse_int(params["limit"], 20), offset: parse_int(params["offset"], 0)]
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  def strategy(strategy) do
    %{
      "id" => strategy.id,
      "name" => strategy.name,
      "notes" => strategy.notes,
      "asset_class" => strategy.asset_class,
      "inserted_at" => str(strategy.inserted_at)
    }
  end

  @doc """
  `version.tags` must already be preloaded (or the field left
  `#Ecto.Association.NotLoaded<>`, in which case this raises rather
  than silently serializing garbage) — every real caller
  (`StrategyVersionController`'s own actions, `Sim.list_strategy_versions/1`
  and `list_strategy_versions_page/2`) already preloads `:tags`.
  """
  def strategy_version(version) do
    %{
      "id" => version.id,
      "strategy_id" => version.strategy_id,
      "version" => version.version,
      "params" => version.params,
      "rules" => version.rules,
      "usage_conditions" => version.usage_conditions,
      "position_sizing" => version.position_sizing,
      "direction" => version.direction,
      "option_leg_config" => version.option_leg_config,
      "lifecycle_stage" => version.lifecycle_stage,
      "quarantine_started_at" => str(version.quarantine_started_at),
      "quarantine_trading_days" => version.quarantine_trading_days,
      "retired_reason" => version.retired_reason,
      "activated_at" => str(version.activated_at),
      "deactivated_at" => str(version.deactivated_at),
      "trading_hours_policy" => version.trading_hours_policy,
      "overnight_hold" => version.overnight_hold,
      "live_strategy_app" => version.live_strategy_app,
      "live_strategy_id" => version.live_strategy_id,
      "live_strategy_active" => version.live_strategy_active,
      "live_linked_at" => str(version.live_linked_at),
      "live_unlinked_at" => str(version.live_unlinked_at),
      "target_pool_id" => version.target_pool_id,
      "source" => version.source,
      "notes" => version.notes,
      # ALWAYS present, even when empty -- an absent key cannot be
      # distinguished from "this client didn't know to look", which is
      # the whole failure mode Caveat exists to close. [] / false is a
      # positive statement that nothing is flagged.
      "caveats" => Enum.map(Caveat.parse(version.notes), &Caveat.to_map/1),
      "has_open_caveat" => Caveat.open?(version.notes),
      "rating" => version.rating,
      "tags" => tags(version.tags),
      "inserted_at" => str(version.inserted_at)
    }
  end

  @doc "`run.tags` and `run.strategy_version` must already be preloaded — see `sim_run/1`'s own callers."
  def sim_run(run) do
    %{
      "id" => run.id,
      "strategy_version_id" => run.strategy_version_id,
      "symbol" => run.symbol,
      "expiry" => run.expiry,
      "strike" => str(run.strike),
      "right" => run.right,
      "multiplier" => run.multiplier,
      "direction" => run.direction,
      "status" => run.status,
      "entry_at" => str(run.entry_at),
      "entry_price" => str(run.entry_price),
      "exit_at" => str(run.exit_at),
      "exit_price" => str(run.exit_price),
      "exit_reason" => run.exit_reason,
      "realized_pnl" => str(run.realized_pnl),
      "realized_pnl_net" => str(run.realized_pnl_net),
      "context" => run.context,
      "tags" => tags(run.tags),
      "inserted_at" => str(run.inserted_at)
    }
  end

  def target_pool(pool) do
    %{
      "id" => pool.id,
      "name" => pool.name,
      "description" => pool.description,
      "region" => pool.region,
      "inverse" => pool.inverse
    }
  end

  def target_pool_member(member) do
    %{
      "id" => member.id,
      "target_pool_id" => member.target_pool_id,
      "symbol" => member.symbol,
      "exchange" => member.exchange,
      "currency" => member.currency,
      "ib_conid" => member.ib_conid
    }
  end

  def tag(tag) do
    %{"id" => tag.id, "name" => tag.name, "description" => tag.description}
  end

  @doc """
  One `Sim.full_universe_version_metrics/0` row plus its
  `CandidateGates.evaluate/2` verdicts — the same data
  `CandidatesLive` renders, for `GET /api/v1/versions/metrics` and the
  `list_candidate_metrics` MCP tool.

  `handoff_prompts/perf_contract/0_SPEC.md` is the authority on every
  field name, unit and population in this payload. Do not add a field
  it does not list, and do not restate a definition here — an earlier
  version of this docstring claimed these names "match TradingSystem's
  own equivalent ... so an operator reads one vocabulary," and that
  claim is exactly what let `final_score` mean two things a factor of
  10^6 apart in the two apps.

  Three fields carry the differences that remain, per row:
  `r_denominator` and `capital_basis` are both `"premium_at_risk"`
  here (the equities apps use stop distance and entry notional), and
  `cost_basis` is `"measured"` because this app derives its cost floor
  from real per-fill commissions rather than a slippage estimate.
  `avg_hold_seconds` has no `trading_system` counterpart — this app's
  own addition.

  This row's Decimal fields are converted to native JSON numbers via
  `decimal_or_float/1`, not the module's usual `str/1` — matching
  `trading_system`'s own metrics-row serializer, which does the same
  for this specific payload (unlike every other function in this
  module, which stringifies Decimals).
  """
  def candidate_metrics(row) do
    %{
      "strategy_version_id" => row.strategy_version_id,
      "strategy_id" => row.strategy_id,
      "strategy_name" => row.strategy_name,
      "version" => row.version,
      "lifecycle_stage" => row.lifecycle_stage,
      "direction" => row.direction,
      "rules" => row.rules,
      "rating" => row.rating,
      "tags" => tags(row.tags),
      "target_pool_id" => row.target_pool_id,
      "target_pool_name" => row.target_pool_name,
      "quarantine_trading_days" => row.quarantine_trading_days,

      # Population
      "basis" => row.basis,
      "churn" => row.churn,
      "r_denominator" => row.r_denominator,
      "n_closes" => row.n_closes,
      "excluded_count" => row.excluded_count,
      "excluded_pnl" => decimal_or_float(row.excluded_pnl),
      "first_traded_on" => str(row.first_traded_on),
      "last_traded_on" => str(row.last_traded_on),

      # Per-trade
      "expectancy_r" => decimal_or_float(row.expectancy_r),
      "sd_r" => decimal_or_float(row.sd_r),
      "total_r" => decimal_or_float(row.total_r),

      # Per-session
      "n_sessions" => row.n_sessions,
      "mean_daily_r" => decimal_or_float(row.mean_daily_r),
      "sd_daily_r" => decimal_or_float(row.sd_daily_r),

      # Money
      "realized_pnl" => decimal_or_float(row.realized_pnl),
      "realized_pnl_gross" => decimal_or_float(row.realized_pnl_gross),

      # Cost
      "avg_commission" => str(row.avg_commission),
      "required_r" => decimal_or_float(row.required_r),
      "cost_basis" => row.cost_basis,
      "cost_margin" => decimal_or_float(row.cost_margin),

      # Capital
      "capital_hours" => decimal_or_float(row.capital_hours),
      "capital_basis" => row.capital_basis,
      "avg_hold_seconds" => str(row.avg_hold_seconds),
      "scored_runs" => row.scored_runs,
      "scored_runs_coverage" => row.scored_runs_coverage,
      "scored_total_r" => decimal_or_float(row.scored_total_r),
      "scored_expectancy_r" => decimal_or_float(row.scored_expectancy_r),
      "final_score" => decimal_or_float(row.final_score),
      "final_score_scale" => row.final_score_scale,

      # Bounds (ucb95/ucb90 intentionally absent — see 0_SPEC.md)
      "lcb95" => row.lcb95,

      # Derived
      "sr_trade" => row.sr_trade,
      "t_trade" => row.t_trade,
      "sr_session" => row.sr_session,
      "sr_annual" => row.sr_annual,

      # Envelope
      "schema_version" => row.schema_version,
      "computed_through" => str_datetime(row.computed_through),
      "exit_reason_histogram" => row.exit_reason_histogram,
      "gates" => TradingOptionsSim.CandidateGates.evaluate(row)
    }
  end

  defp str_datetime(nil), do: nil
  defp str_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp tags(tags) when is_list(tags), do: Enum.map(tags, &tag/1)

  defp str(nil), do: nil
  defp str(%Decimal{} = d), do: Decimal.to_string(d)
  defp str(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp str(%Date{} = d), do: Date.to_iso8601(d)
  defp str(other), do: other

  # candidate_metrics/1's own exception to this module's usual str/1
  # (Decimal -> string) convention — matches trading_system's own
  # metrics-row serializer, which converts this specific payload's
  # Decimal fields to native JSON floats instead.
  defp decimal_or_float(nil), do: nil
  defp decimal_or_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_or_float(value) when is_float(value), do: value
end
