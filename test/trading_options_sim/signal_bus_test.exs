defmodule TradingOptionsSim.SignalBusTest do
  use ExUnit.Case, async: false

  alias TradingOptionsSim.SignalBus
  alias TradingOptionsSim.SignalBus.Test, as: SignalBusTest

  # async: false — SignalBus.Test is a named singleton Agent shared
  # across the suite (config/test.exs sets :signal_bus_adapter to it).

  setup do
    SignalBusTest.reset()
    :ok
  end

  test "request/1 defaults to a signals:<name> topic when nothing is stubbed" do
    assert {:ok, "signals:vix_regime"} = SignalBus.request("vix_regime")
  end

  test "request/1 returns a stubbed topic when one is set" do
    SignalBusTest.stub_topic("vix_regime", "signals:definition:abc-123")

    assert {:ok, "signals:definition:abc-123"} = SignalBus.request("vix_regime")
  end

  test "requested_names/0 records every name request/1 was called with" do
    SignalBus.request("vix_regime")
    SignalBus.request("spy_trend")

    assert SignalBusTest.requested_names() == ["spy_trend", "vix_regime"]
  end
end
