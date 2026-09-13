defmodule TradingOptionsSim.SignalBus.Live do
  @moduledoc """
  Real `TradingOptionsSim.SignalBus` adapter — delegates to
  `TradingOptionsSim.SignalConnection.request_signal/1`'s erpc call
  against the `trading_signal` node. The default adapter outside of
  `:test` env.
  """

  @behaviour TradingOptionsSim.SignalBus

  alias TradingOptionsSim.SignalConnection

  @impl true
  def request(name), do: SignalConnection.request_signal(name)
end
