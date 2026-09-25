defmodule TradingOptionsSim.Sim.PromotionExport do
  @moduledoc """
  Everything trading_live needs to promote one strategy version, in one
  stable payload: `GET /api/v1/versions/:id/promotion_export`.

  Shape agreed with trading_live in its `OPTIONS_PROMOTION_PLAN.md`
  ("Cross-app contract"). **Changing a field is a contract change**: bump
  `schema_version` and tell trading_live, rather than editing in place.

  * `rules`, `params`, `option_leg_config`, `position_sizing` -- copied
    byte-for-byte into the live strategy.
  * `target_pool.members[].ib_conid` -- the UNDERLYING's conid when
    known, never an option's; the option contract is resolved daily.
  * `execution` -- `ContractMonitor.execution_defaults/0`, so live limit
    prices and expiry closes match how this simulator fills.
  * `snapshot_keys` -- `ContractMonitor.snapshot_keys/0`, the keys this
    app writes, so trading_live's capability check is driven by the
    source rather than a copied list.
  * `content_hash` -- SHA-256 (lowercase hex) of the canonical JSON of
    `%{"option_leg_config", "params", "rules"}`: object keys sorted at
    every depth, no whitespace. Map ordering can't change it; any change
    to the three fields does. Lets trading_live spot a re-promotion of
    changed rules. Reproducible anywhere; it equals Python's
    `sha256(json.dumps(d, sort_keys=True, separators=(",", ":")))`, which
    a golden-value test pins.
  """

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.Repo
  alias TradingOptionsSim.Sim.StrategyVersion

  @schema_version 1

  @spec build(String.t()) :: {:ok, map()} | {:error, :not_found}
  def build(version_id) do
    # A malformed id is "not found", not a cast crash (500).
    with {:ok, uuid} <- Ecto.UUID.cast(version_id),
         %StrategyVersion{} = version <- Repo.get(StrategyVersion, uuid) do
      {:ok,
       version |> Repo.preload([:strategy, target_pool: :target_pool_members]) |> to_payload()}
    else
      _ -> {:error, :not_found}
    end
  end

  defp to_payload(v) do
    %{
      "schema_version" => @schema_version,
      "strategy_version_id" => v.id,
      "strategy_id" => v.strategy_id,
      "strategy_name" => v.strategy && v.strategy.name,
      "version" => v.version,
      "lifecycle_stage" => v.lifecycle_stage,
      "rules" => v.rules,
      "position_sizing" => v.position_sizing,
      "params" => v.params,
      "direction" => v.direction,
      "option_leg_config" => v.option_leg_config,
      "trading_hours_policy" => v.trading_hours_policy,
      "overnight_hold" => v.overnight_hold,
      "lineage" => %{
        "parent_version_id" => v.parent_version_id,
        "generation" => v.generation,
        "source" => v.source
      },
      "target_pool" => target_pool(v.target_pool),
      "execution" =>
        Map.new(ContractMonitor.execution_defaults(), fn {k, val} -> {to_string(k), val} end),
      "snapshot_keys" => ContractMonitor.snapshot_keys(),
      "content_hash" => content_hash(v)
    }
  end

  defp target_pool(nil), do: nil

  defp target_pool(pool) do
    %{
      "id" => pool.id,
      "name" => pool.name,
      "members" =>
        pool.target_pool_members
        |> Enum.sort_by(& &1.symbol)
        |> Enum.map(fn m ->
          %{
            "symbol" => m.symbol,
            "exchange" => m.exchange,
            "currency" => m.currency,
            "ib_conid" => m.ib_conid
          }
        end)
    }
  end

  @doc "See the moduledoc. Public so the hash can be reproduced and tested."
  @spec content_hash(StrategyVersion.t() | map()) :: String.t()
  def content_hash(%{rules: rules, params: params, option_leg_config: leg}) do
    %{"option_leg_config" => leg || %{}, "params" => params || %{}, "rules" => rules || %{}}
    |> canonical()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Maps become Jason.OrderedObject with keys sorted, recursively, so the
  # encoding is independent of map iteration order.
  defp canonical(%{} = map) when not is_struct(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: other
end
