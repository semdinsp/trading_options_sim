defmodule TradingOptionsSim.Pricing.IBKRLiveTest do
  use ExUnit.Case, async: false

  alias TradingOptionsSim.Pricing.IBKRLive

  # async: false — each test starts a real named-via-Registry GenServer;
  # keeping the OCC symbol unique per test avoids cross-test collisions
  # without needing serialized access to a shared name.

  defp occ_symbol, do: "SYM# #{System.unique_integer([:positive])}"

  defp contract, do: %{sec_type: "OPT", expiry: "20271231", strike: 150.0, right: "C"}

  defp broadcast_greeks(occ_symbol, data) do
    message =
      %{type: :price, symbol: occ_symbol, source: :ibkr, data: data}
      |> Map.put(:__struct__, TradingHub.Message)

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:#{occ_symbol}", message)
  end

  describe "latest/1" do
    test "returns {:error, :no_data} when no listener is running" do
      assert {:error, :no_data} = IBKRLive.latest("never-started")
    end

    test "returns {:error, :no_data} before any tick arrives" do
      symbol = occ_symbol()
      start_supervised!({IBKRLive, occ_symbol: symbol, contract: contract()})

      assert {:error, :no_data} = IBKRLive.latest(symbol)
    end

    test "returns the last-received greeks tick" do
      symbol = occ_symbol()
      start_supervised!({IBKRLive, occ_symbol: symbol, contract: contract()})

      broadcast_greeks(symbol, %{
        implied_vol: 0.35,
        delta: 0.55,
        opt_price: 5.2,
        pv_dividend: 0.0,
        gamma: 0.02,
        vega: 0.15,
        theta: -0.03,
        und_price: 150.25
      })

      Process.sleep(50)

      assert {:ok, tick} = IBKRLive.latest(symbol)
      assert tick.price == 5.2
      assert tick.delta == 0.55
      assert tick.gamma == 0.02
      assert tick.theta == -0.03
      assert tick.vega == 0.15
      assert tick.implied_vol == 0.35
      assert tick.underlying_price == 150.25
    end

    test "a later tick replaces the earlier one" do
      symbol = occ_symbol()
      start_supervised!({IBKRLive, occ_symbol: symbol, contract: contract()})

      broadcast_greeks(symbol, %{delta: 0.50, opt_price: 5.0})
      Process.sleep(30)
      broadcast_greeks(symbol, %{delta: 0.60, opt_price: 5.5})
      Process.sleep(30)

      assert {:ok, tick} = IBKRLive.latest(symbol)
      assert tick.delta == 0.60
      assert tick.price == 5.5
    end

    test "ignores a broadcast on the same topic with no greeks keys" do
      symbol = occ_symbol()
      start_supervised!({IBKRLive, occ_symbol: symbol, contract: contract()})

      # A plain stock-shaped tick (bid/ask/last) — shouldn't happen if the
      # OCC-symbol convention is respected, but confirms this module
      # never fabricates greeks from unrelated data.
      broadcast_greeks(symbol, %{bid: 100.0, ask: 100.5, last: 100.2})
      Process.sleep(30)

      assert {:error, :no_data} = IBKRLive.latest(symbol)
    end

    test "treats an absent key as nil, never fabricated" do
      symbol = occ_symbol()
      start_supervised!({IBKRLive, occ_symbol: symbol, contract: contract()})

      broadcast_greeks(symbol, %{delta: 0.5})
      Process.sleep(30)

      assert {:ok, tick} = IBKRLive.latest(symbol)
      assert tick.delta == 0.5
      assert is_nil(tick.gamma)
      assert is_nil(tick.price)
    end
  end

  describe "whereis/1" do
    test "finds a running listener by occ_symbol" do
      symbol = occ_symbol()
      {:ok, pid} = start_supervised({IBKRLive, occ_symbol: symbol, contract: contract()})

      assert IBKRLive.whereis(symbol) == pid
    end

    test "returns nil for a symbol with no running listener" do
      assert IBKRLive.whereis("nonexistent") == nil
    end
  end
end
