defmodule TradingOptionsSim.SimActivatorOccSymbolTest do
  use ExUnit.Case, async: true

  # SimActivator.occ_symbol/1 now builds through the shared
  # TradingContract.OccSymbol (trading_contract v0.2.1), replacing this
  # app's own OccSymbol module. These are the old module's regression
  # values, kept verbatim: the strings are subscription and Registry keys
  # ({:ibkr_live, occ_symbol}), so any byte of drift is silent
  # non-delivery.

  alias TradingOptionsSim.SimActivator

  defp occ(symbol, expiry, strike, right),
    do: SimActivator.occ_symbol({symbol, expiry, Decimal.new(strike), right})

  test "matches trading_hub's own verified real example (AAPL 150 call, exp 2025-01-17)" do
    assert occ("AAPL", "20250117", "150.00", "C") == {:ok, "AAPL  250117C00150000"}
  end

  test "builds the correct symbol for our real SPY 762 call, exp 2026-11-20" do
    assert occ("SPY", "20261120", "762.00", "C") == {:ok, "SPY   261120C00762000"}
  end

  test "builds the correct symbol for a put" do
    assert occ("SPY", "20261120", "762.00", "P") == {:ok, "SPY   261120P00762000"}
  end

  test "pads a 1-character symbol to 6 characters" do
    assert occ("F", "20261120", "15.00", "C") == {:ok, "F     261120C00015000"}
  end

  test "handles a strike with a fractional dollar amount" do
    assert occ("SPY", "20261120", "762.50", "C") == {:ok, "SPY   261120C00762500"}
  end

  test "the full symbol is always exactly 21 characters" do
    for root <- ~w(F SPY GOOGL) do
      assert {:ok, s} = occ(root, "20261120", "150.00", "C")
      assert String.length(s) == 21
    end
  end

  # Sub-cent strikes must round exactly as the old builder did.
  # occ_symbol/1 passes exact thousandths rather than a float, as
  # trading_contract recommends. Note this test would ALSO pass via a
  # float for these values (checked), so it pins the output, not the path.
  test "a sub-cent strike rounds the same way the old builder did" do
    assert occ("SPY", "20261120", "150.005", "C") == {:ok, "SPY   261120C00150005"}
    assert occ("SPY", "20261120", "12.125", "C") == {:ok, "SPY   261120C00012125"}
  end

  test "invalid input is :error, not a crash" do
    assert occ("spy", "20261120", "150.00", "C") == :error
    assert occ("SPY", "20261131", "150.00", "C") == :error
    assert SimActivator.occ_symbol(:not_a_contract) == :error
  end
end
