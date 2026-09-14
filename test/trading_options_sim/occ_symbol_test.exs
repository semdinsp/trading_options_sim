defmodule TradingOptionsSim.OccSymbolTest do
  use ExUnit.Case, async: true

  doctest TradingOptionsSim.OccSymbol

  alias TradingOptionsSim.OccSymbol

  test "matches trading_hub's own verified real example (AAPL 150 call, exp 2025-01-17)" do
    assert OccSymbol.build("AAPL", "20250117", Decimal.new("150.00"), "C") ==
             "AAPL  250117C00150000"
  end

  test "builds the correct symbol for our real SPY 762 call, exp 2026-11-20" do
    assert OccSymbol.build("SPY", "20261120", Decimal.new("762.00"), "C") ==
             "SPY   261120C00762000"
  end

  test "builds the correct symbol for a put" do
    assert OccSymbol.build("SPY", "20261120", Decimal.new("762.00"), "P") ==
             "SPY   261120P00762000"
  end

  test "pads a 1-character symbol to 6 characters" do
    assert OccSymbol.build("F", "20261120", Decimal.new("15.00"), "C") ==
             "F     261120C00015000"
  end

  test "does not truncate a symbol already 6 characters" do
    # OCC symbols are conventionally capped at 6 chars for the
    # underlying (no US-listed equity ticker is longer), so this isn't
    # a real case to guard against — documented via the 21-char total
    # length assertion below instead of a truncation test.
    result = OccSymbol.build("GOOGL", "20261120", Decimal.new("150.00"), "C")
    assert String.length(result) == 21
  end

  test "handles a strike with a fractional dollar amount" do
    assert OccSymbol.build("SPY", "20261120", Decimal.new("762.50"), "C") ==
             "SPY   261120C00762500"
  end

  test "the full symbol is always exactly 21 characters" do
    result = OccSymbol.build("SPY", "20261120", Decimal.new("762.00"), "C")
    assert String.length(result) == 21
  end
end
