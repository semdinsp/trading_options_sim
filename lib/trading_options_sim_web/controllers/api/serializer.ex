defmodule TradingOptionsSimWeb.Api.Serializer do
  @moduledoc """
  Plain-map JSON shapes for `/api/v1` — no separate JSON view modules,
  matching `trading_system`'s own convention for this size of API.
  `Decimal`/`DateTime` values are stringified explicitly since `Jason`
  doesn't encode `Decimal` by default.
  """

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
      "live_strategy_app" => version.live_strategy_app,
      "live_strategy_id" => version.live_strategy_id,
      "live_strategy_active" => version.live_strategy_active,
      "live_linked_at" => str(version.live_linked_at),
      "live_unlinked_at" => str(version.live_unlinked_at),
      "target_pool_id" => version.target_pool_id,
      "source" => version.source,
      "notes" => version.notes,
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

  defp tags(tags) when is_list(tags), do: Enum.map(tags, &tag/1)

  defp str(nil), do: nil
  defp str(%Decimal{} = d), do: Decimal.to_string(d)
  defp str(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp str(%Date{} = d), do: Date.to_iso8601(d)
  defp str(other), do: other
end
