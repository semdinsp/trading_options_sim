defmodule TradingOptionsSimWeb.StrategySearchTest do
  use ExUnit.Case, async: true

  alias TradingOptionsSimWeb.StrategySearch

  @id "01a0c043-d68d-7f0b-a52a-f170e22e42ce"

  test "an empty or blank query matches everything" do
    assert StrategySearch.matches?("", "Anything", [@id])
    assert StrategySearch.matches?("   ", "Anything", [@id])
    assert StrategySearch.matches?(nil, "Anything", [@id])
  end

  test "name matches are case-insensitive substrings" do
    assert StrategySearch.matches?("slope", "Slope Momentum Call 45d", [])
    assert StrategySearch.matches?("MOMENTUM call", "Slope Momentum Call 45d", [])
    refute StrategySearch.matches?("vwap", "Slope Momentum Call 45d", [])
  end

  test "a full UUID or a prefix of it matches the id" do
    assert StrategySearch.matches?(@id, "Unrelated", [@id])
    assert StrategySearch.matches?("01a0c043", "Unrelated", [@id])
    assert StrategySearch.matches?("  01A0C043-D68D ", "Unrelated", [@id])
    refute StrategySearch.matches?("01a0c044", "Unrelated", [@id])
  end

  # Must not fire on healthy input: a short hex word is not a UUID
  # fragment, so it can't pull in rows by accident through their ids.
  test "a short hex word doesn't match ids, but still matches names" do
    id = "0000dead-0000-0000-0000-000000000000"
    refute StrategySearch.matches?("dead", "Momentum", [id])
    assert StrategySearch.matches?("dead", "Deadband Call", [id])
  end

  # UUIDv7: rows created in the same millisecond share the first 8 hex
  # characters, so a prefix can match several; the tail is distinctive.
  test "a UUIDv7 timestamp prefix can match several rows; the tail picks one" do
    a = "01a0d08c-bf78-7314-b53b-a0d18cb35313"
    b = "01a0d08c-bfd4-72e9-8e56-2b8b6eb9e07a"
    items = [%{n: "A", id: a}, %{n: "B", id: b}]
    fields = &{&1.n, [&1.id]}

    assert length(StrategySearch.filter(items, "01a0d08c", fields)) == 2
    assert StrategySearch.filter(items, "2b8b6eb9e07a", fields) == [%{n: "B", id: b}]
  end

  test "filter/3 keeps matching items and tolerates nil ids" do
    items = [%{n: "Alpha", id: @id}, %{n: "Beta", id: nil}]
    fields = &{&1.n, [&1.id]}

    assert StrategySearch.filter(items, "alp", fields) == [hd(items)]
    assert StrategySearch.filter(items, "01a0c043", fields) == [hd(items)]
    assert StrategySearch.filter(items, "", fields) == items
  end
end
