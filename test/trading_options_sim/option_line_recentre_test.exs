defmodule TradingOptionsSim.OptionLineRecentreTest do
  # 2026-11-23: trading_hub was short of IBKR market-data lines and
  # reported 152 option lines with no owner. They were this app's: each
  # IBKRLive listener used the bare OCC symbol as its caller tag, and each
  # monitor kept its activation-day strike for life, spreading SPY over 42
  # lines and QQQ over 34.
  use ExUnit.Case, async: true

  alias TradingOptionsSim.Pricing.IBKRLive
  alias TradingOptionsSim.SimActivator

  describe "IBKRLive caller tags" do
    test "the tag names this app, so trading_hub can attribute the line" do
      assert IBKRLive.caller_tag("SPY   270115P00715000") ==
               "trading_options_sim:SPY   270115P00715000"
    end

    test "the legacy tag is the bare OCC symbol (released after each subscribe)" do
      occ = "QQQ   261218C00720000"
      assert IBKRLive.legacy_caller_tag(occ) == occ
      refute IBKRLive.legacy_caller_tag(occ) == IBKRLive.caller_tag(occ)
    end
  end

  describe "flat_and_drifted?/2" do
    @atm %{"strike_selection" => "atm_offset", "right" => "P", "strike_offset" => 0}

    defp snap(strike, spot, opts \\ []) do
      %{
        symbol: Keyword.get(opts, :symbol, "SPY"),
        strike: Decimal.new(strike),
        position_open?: Keyword.get(opts, :open?, false),
        last_snapshot: if(spot, do: %{"run_underlying_price" => spot}, else: nil)
      }
    end

    test "re-centres a flat monitor two or more grid steps from today's ATM" do
      # SPY's grid is $5, so two steps is $10.
      assert SimActivator.flat_and_drifted?(snap("700", 712.0), @atm)
      assert SimActivator.flat_and_drifted?(snap("730", 720.0), @atm)
    end

    test "leaves a monitor within two grid steps alone" do
      refute SimActivator.flat_and_drifted?(snap("715", 712.0), @atm)
      refute SimActivator.flat_and_drifted?(snap("705", 712.0), @atm)
    end

    test "measures drift from spot + strike_offset" do
      itm = Map.put(@atm, "strike_offset", 5)
      refute SimActivator.flat_and_drifted?(snap("715", 712.0), itm)
      assert SimActivator.flat_and_drifted?(snap("700", 712.0), itm)
    end

    test "uses the symbol's own grid (XLF $1)" do
      assert SimActivator.flat_and_drifted?(snap("50", 52.2, symbol: "XLF"), @atm)
      refute SimActivator.flat_and_drifted?(snap("51", 52.2, symbol: "XLF"), @atm)
    end

    test "never re-centres a monitor holding a position" do
      refute SimActivator.flat_and_drifted?(snap("650", 712.0, open?: true), @atm)
    end

    test "never re-centres a fixed-strike config" do
      fixed = %{"strike_selection" => "fixed_strike", "fixed_strike" => "650", "right" => "P"}
      refute SimActivator.flat_and_drifted?(snap("650", 712.0), fixed)
    end

    test "doesn't roll without a spot" do
      refute SimActivator.flat_and_drifted?(snap("650", nil), @atm)
      refute SimActivator.flat_and_drifted?(nil, @atm)
    end
  end
end
