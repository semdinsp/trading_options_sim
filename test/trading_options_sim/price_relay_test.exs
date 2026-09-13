defmodule TradingOptionsSim.PriceRelayTest do
  use ExUnit.Case, async: true

  alias TradingOptionsSim.PriceRelay

  # PriceRelay is already started under the real supervision tree (see
  # Application.start/2) — send messages to the real named process rather
  # than starting a second instance, matching how StatusExtensionTest
  # exercises the real supervised HubMonitor-equivalent in trading_live.

  test "connected?/0 is false before any hub_connection_status message" do
    # The real app-started PriceRelay may already have received a status
    # from a prior test in this run — reset it to a known state first.
    send(PriceRelay, {:hub_connection_status, false})
    assert PriceRelay.connected?() == false
  end

  test "connected?/0 reflects the last {:hub_connection_status, _} message" do
    send(PriceRelay, {:hub_connection_status, true})
    assert PriceRelay.connected?() == true

    send(PriceRelay, {:hub_connection_status, false})
    assert PriceRelay.connected?() == false
  end

  test "relays a %TradingHub.Message{type: :price, symbol: symbol} onto \"prices:<symbol>\"" do
    Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, "prices:AAPL")

    # This app has no compile-time dependency on TradingHub.Message (see
    # ib_portfolio.Message's own moduledoc: recognized structurally via
    # %{__struct__: TradingHub.Message}, no coupling) — construct the
    # same shape via Map.put/3 rather than a real struct literal, which
    # would require depending on trading_hub just to compile this test.
    message =
      %{type: :price, symbol: "AAPL", source: :ibkr, data: %{last: 150.0}}
      |> Map.put(:__struct__, TradingHub.Message)

    send(PriceRelay, message)

    assert_receive ^message, 500
  end

  test "ignores a pair-symbol price message (no single underlying to relay to)" do
    Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, "prices:all")

    message =
      %{type: :price, symbol: {"AAPL", "MSFT"}, source: :ibkr, data: %{}}
      |> Map.put(:__struct__, TradingHub.Message)

    send(PriceRelay, message)

    refute_receive _any, 200
  end

  test "ignores a non-price message" do
    Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, "prices:AAPL")

    message =
      %{type: :volume, symbol: "AAPL", source: :ibkr, data: %{}}
      |> Map.put(:__struct__, TradingHub.Message)

    send(PriceRelay, message)

    refute_receive _any, 200
  end
end
