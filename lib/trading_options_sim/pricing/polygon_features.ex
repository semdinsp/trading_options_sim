defmodule TradingOptionsSim.Pricing.PolygonFeatures do
  @moduledoc """
  Per-symbol Polygon underlying features, exposed to rule trees as
  `run_poly_*` snapshot keys.

  The computation lives in `TradingCore.Polygon.UnderlyingFeatures`
  (moved there 2026-09-24, trading_core PR #52) so that trading_options_sim
  and trading_live compute identical values: strategies are promoted
  with their rule trees copied byte-for-byte, so both apps must mean the
  same thing by `run_poly_vwap_dev_bps`. That module's moduledoc is the
  reference for every key, the clock (the hub's `data[:timestamp]`), the
  staleness windows, and why an unknown value is ABSENT rather than 0.

  What stays here is app-specific: the ETS table, owned by
  `TradingOptionsSim.PolygonRelay`, which folds every relayed message
  into it, and `snapshot/1`, which `ContractMonitor` merges into each
  evaluation.
  """

  alias TradingCore.Polygon.UnderlyingFeatures

  @table __MODULE__

  @type t :: UnderlyingFeatures.t()

  defdelegate new(), to: UnderlyingFeatures
  defdelegate apply_trade(f, data, fallback_ms), to: UnderlyingFeatures
  defdelegate apply_quote(f, data, fallback_ms), to: UnderlyingFeatures
  defdelegate apply_aggregate(f, data, fallback_ms), to: UnderlyingFeatures
  defdelegate to_snapshot(f, now_ms), to: UnderlyingFeatures

  # --- ETS ------------------------------------------------------------------

  @doc "Creates the named table. Called once by `PolygonRelay.init/1`, which owns it."
  @spec create_table() :: :ok
  def create_table do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    :ok
  end

  @doc "Current features for `symbol` (or a fresh struct if none)."
  @spec get(String.t()) :: t()
  def get(symbol) do
    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, symbol) do
      [{^symbol, features}] -> features
      _ -> new()
    end
  end

  @doc false
  @spec put(String.t(), t()) :: true
  def put(symbol, features), do: :ets.insert(@table, {symbol, features})

  @doc "The `run_poly_*` snapshot for `symbol` right now — `%{}` if nothing is known."
  @spec snapshot(String.t()) :: map()
  def snapshot(symbol), do: symbol |> get() |> to_snapshot(now_ms())

  @doc false
  def now_ms, do: System.system_time(:millisecond)
end
