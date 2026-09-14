defmodule TradingOptionsSimWeb.Api.Serializer do
  @moduledoc """
  Plain-map JSON shapes for `/api/v1` — no separate JSON view modules,
  matching `trading_system`'s own convention for this size of API.
  `Decimal`/`DateTime` values are stringified explicitly since `Jason`
  doesn't encode `Decimal` by default.
  """

  def strategy(strategy) do
    %{
      "id" => strategy.id,
      "name" => strategy.name,
      "notes" => strategy.notes,
      "asset_class" => strategy.asset_class,
      "inserted_at" => str(strategy.inserted_at)
    }
  end

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
      "live_strategy_app" => version.live_strategy_app,
      "live_strategy_id" => version.live_strategy_id,
      "live_strategy_active" => version.live_strategy_active,
      "live_linked_at" => str(version.live_linked_at),
      "live_unlinked_at" => str(version.live_unlinked_at),
      "target_pool_id" => version.target_pool_id,
      "source" => version.source,
      "notes" => version.notes,
      "rating" => version.rating,
      "inserted_at" => str(version.inserted_at)
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

  defp str(nil), do: nil
  defp str(%Decimal{} = d), do: Decimal.to_string(d)
  defp str(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp str(%Date{} = d), do: Date.to_iso8601(d)
  defp str(other), do: other
end
