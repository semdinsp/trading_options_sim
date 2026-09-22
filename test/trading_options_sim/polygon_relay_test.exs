defmodule TradingOptionsSim.PolygonRelayTest do
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.PolygonRelay

  # This app has no compile-time dependency on TradingHub.Message (see
  # IbPortfolio.Message's own moduledoc) -- construct the same shape via
  # Map.put/3 rather than a struct literal, which would require
  # depending on trading_hub just to compile this test.
  defp hub_message(symbol, data_type, data) do
    %{
      type: if(data_type == :ws_aggregate, do: :volume, else: :price),
      source: :polygon,
      symbol: symbol,
      data: data,
      metadata: %{source: "polygon.io", data_type: data_type}
    }
    |> Map.put(:__struct__, TradingHub.Message)
  end

  describe "topic separation" do
    # The one property that must never regress: Polygon data must not
    # land on IBKR's topic. PolygonStreamer's own moduledoc explains why
    # -- no consumer filters on Message.source, so a merged topic means
    # whichever message arrives last silently overwrites the other.
    test "local topics are distinct from IBKR's prices:SYMBOL" do
      assert PolygonRelay.prices_topic("SPY") == "polygon:prices:SPY"
      assert PolygonRelay.volume_topic("SPY") == "polygon:volume:SPY"

      refute PolygonRelay.prices_topic("SPY") == "prices:SPY"
      refute PolygonRelay.volume_topic("SPY") == "volume:SPY"
    end
  end

  describe "dispatch on metadata.data_type" do
    setup do
      :ok = PolygonRelay.watch("RELAYTEST")

      Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, PolygonRelay.prices_topic("RELAYTEST"))
      Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, PolygonRelay.volume_topic("RELAYTEST"))

      :ok
    end

    test "relays a trade onto the prices topic" do
      msg = hub_message("RELAYTEST", :ws_trade, %{last: Decimal.new("100.25")})
      send(PolygonRelay, msg)

      assert_receive ^msg, 500
    end

    # THE test that earns its keep. Trades and quotes share a topic and
    # have disjoint payloads, so a handler matching `data: %{last: last}`
    # compiles, runs, and silently drops every quote -- ~78% of traffic
    # on a measured SPY capture, and a live bug in trading_signal's own
    # DefinitionSignal. A quote carries no `last` at all.
    test "relays a quote, which carries no :last key whatsoever" do
      data = %{
        bid: Decimal.new("100.20"),
        ask: Decimal.new("100.30"),
        bid_size: Decimal.new("5"),
        ask_size: Decimal.new("8")
      }

      refute Map.has_key?(data, :last)

      msg = hub_message("RELAYTEST", :ws_quote, data)
      send(PolygonRelay, msg)

      assert_receive ^msg, 500
    end

    test "relays an aggregate onto the VOLUME topic, not the prices one" do
      msg =
        hub_message("RELAYTEST", :ws_aggregate, %{volume: 1200, cumulative_volume: 98_000})

      send(PolygonRelay, msg)

      assert_receive ^msg, 500

      # Must not also appear on the prices topic -- this test subscribes
      # to both, so a misrouted aggregate would arrive twice.
      refute_receive ^msg, 100
    end

    # nil means unknown, not zero. Passed through unchanged so a
    # consumer can tell the difference; Decimal.div/2 raises on a zero
    # denominator, so collapsing nil to 0 would turn "unknown" into a
    # crash or a wrong number.
    test "passes nil sizes through rather than coercing them" do
      msg =
        hub_message("RELAYTEST", :ws_quote, %{
          bid: Decimal.new("100.20"),
          ask: Decimal.new("100.30"),
          bid_size: nil,
          ask_size: nil
        })

      send(PolygonRelay, msg)

      assert_receive %{data: %{bid_size: nil, ask_size: nil}}, 500
    end

    test "ignores an unrecognised data_type without crashing" do
      send(PolygonRelay, hub_message("RELAYTEST", :ws_something_new, %{whatever: 1}))
      send(PolygonRelay, :an_unexpected_atom)
      send(PolygonRelay, {:tuple, :nobody, :handles})

      # A GenServer.call flushes the mailbox: it cannot be served until
      # everything ahead of it has been handled.
      assert is_list(PolygonRelay.watching())
    end
  end

  describe "watch/1" do
    test "is idempotent and tracks watched symbols" do
      :ok = PolygonRelay.watch("WATCHONCE")
      :ok = PolygonRelay.watch("WATCHONCE")

      assert "WATCHONCE" in PolygonRelay.watching()
    end
  end
end
