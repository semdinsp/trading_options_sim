defmodule TradingOptionsSim.SignalBus do
  @moduledoc """
  Seam between `TradingOptionsSim.ContractMonitor` and the sibling
  `trading_signal` app's live signal computations (reached over Erlang
  distribution via `TradingOptionsSim.SignalConnection`, not a local
  process). Mirrors `TradingLive.SignalBus`'s shape exactly — same
  config-swappable adapter pattern, same reason: `ContractMonitor` should
  only ever call `request/1` here, never `TradingOptionsSim.SignalConnection`
  directly, so tests can run against `TradingOptionsSim.SignalBus.Test`
  instead of a live `trading_signal` node.

  No `regime_sessions_between/2` callback here — that's a
  `trading_live`-specific historical-regime-backfill seam
  (`LiveTrading.backfill_fill_regime_from_sessions/2`) this app has no
  analog for; this app only ever needs live signal subscription.
  """

  @callback request(String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Resolves `name` (a `StrategyVersion.rules` tree's `"signal"`/
  `"value_signal"` value — a `trading_signal` `SignalDefinition.slug`) and
  registers the caller as a counted subscriber, returning `{:ok, topic}`
  — subscribe to that exact string via
  `Phoenix.PubSub.subscribe(TradingSignal.PubSub, topic)`. See
  `TradingOptionsSim.SignalConnection.request_signal/1` (the real
  adapter's implementation) for why both steps matter.
  """
  def request(name), do: impl().request(name)

  defp impl,
    do:
      Application.get_env(
        :trading_options_sim,
        :signal_bus_adapter,
        TradingOptionsSim.SignalBus.Live
      )
end
