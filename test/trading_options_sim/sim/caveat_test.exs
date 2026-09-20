defmodule TradingOptionsSim.Sim.CaveatTest do
  use ExUnit.Case, async: true

  alias TradingOptionsSim.Sim.Caveat

  # The real shape: caveats first, blank line, then ordinary prose.
  defp caveated_note do
    """
    CAVEATS FIRST — one live, one permanent.
    (1) HISTORY BEFORE 2026-09-18 IS NOT COMPARABLE: every fill before
    PR #52 priced at a hardcoded 30% implied vol against real ~13-19%,
    inflating premiums roughly 2x.
    (2) DO NOT TRUST THE NAME: expectancy_r here is return-on-premium,
    not return-on-risk.

    Origin: seeded 2026-09-17. Measures: long ATM call on positive slope.
    """
  end

  describe "parse/1" do
    test "returns [] for nil, blank, and an uncaveated note" do
      assert Caveat.parse(nil) == []
      assert Caveat.parse("") == []
      assert Caveat.parse("Puts v4: exit on delta decay. Threshold tuned by hand.") == []
    end

    test "a note merely mentioning the word caveat mid-prose is not a caveat block" do
      # Only a note that OPENS with the block counts. Otherwise any note
      # discussing caveats in passing would parse as carrying one.
      assert Caveat.parse("Origin: manual. One caveat: the strike is stale.") == []
    end

    test "extracts each numbered entry with its label and body, in document order" do
      assert [first, second] = Caveat.parse(caveated_note())

      assert first.label == "HISTORY BEFORE 2026-09-18 IS NOT COMPARABLE"
      assert first.kind == :history
      assert first.body =~ "hardcoded 30% implied vol"
      # Body is newline-collapsed so a consumer can render it on one line.
      refute first.body =~ "\n"

      assert second.label == "DO NOT TRUST THE NAME"
      assert second.kind == :semantic
    end

    test "stops at the blank line, so ordinary prose is never swallowed" do
      caveats = Caveat.parse(caveated_note())

      refute Enum.any?(caveats, &(&1.body =~ "Origin:"))
      refute Enum.any?(caveats, &(&1.body =~ "Measures:"))
    end
  end

  describe "classify" do
    defp kind_of(label) do
      "CAVEATS\n(1) #{label}: body\n\nOrigin: x"
      |> Caveat.parse()
      |> hd()
      |> Map.fetch!(:kind)
    end

    test "classifies each kind from its label" do
      assert kind_of("HISTORY BEFORE 2026-09-18 IS NOT COMPARABLE") == :history
      assert kind_of("DO NOT ACT ON THE NUMBER") == :data
      assert kind_of("PREFER THE POST-HAIRCUT RUNS") == :data
      assert kind_of("DO NOT TRUST THE NAME") == :semantic
      assert kind_of("EXIT-ONLY") == :applicability
      assert kind_of("ENTRY-ONLY") == :applicability
      assert kind_of("SOMETHING ELSE ENTIRELY") == :other
    end
  end

  describe "open?/1" do
    test "data, history and applicability are open" do
      assert Caveat.open?("CAVEATS\n(1) DO NOT ACT ON THE NUMBER: x\n\nOrigin: y")
      assert Caveat.open?("CAVEATS\n(1) HISTORY BEFORE X IS NOT COMPARABLE: x\n\nOrigin: y")
      assert Caveat.open?("CAVEATS\n(1) EXIT-ONLY: x\n\nOrigin: y")
    end

    # The load-bearing case. A :semantic caveat never clears and only a
    # human can act on it, so counting it as open would flag the row
    # forever until the flag stopped being read.
    test "a semantic caveat alone is NOT open" do
      note = "CAVEATS\n(1) DO NOT TRUST THE NAME: measures something else\n\nOrigin: y"

      assert [%{kind: :semantic}] = Caveat.parse(note)
      refute Caveat.open?(note)
    end

    test "a semantic caveat alongside an open one is still open" do
      assert Caveat.open?(caveated_note())
    end

    test "an uncaveated note is not open" do
      refute Caveat.open?("Origin: manual.")
      refute Caveat.open?(nil)
    end
  end

  describe "of_kind/2 and summary/1" do
    test "of_kind filters to one class" do
      assert [%{kind: :history}] = Caveat.of_kind(caveated_note(), :history)
      assert [%{kind: :semantic}] = Caveat.of_kind(caveated_note(), :semantic)
      assert Caveat.of_kind(caveated_note(), :data) == []
    end

    test "summary joins labels, and is nil rather than empty when there are none" do
      assert Caveat.summary(caveated_note()) =~ "DO NOT TRUST THE NAME"
      assert Caveat.summary("Origin: manual.") == nil
      assert Caveat.summary(nil) == nil
    end
  end

  describe "to_map/1" do
    test "renders string keys with the kind as a string" do
      assert %{"kind" => "history", "label" => label, "body" => body} =
               caveated_note() |> Caveat.parse() |> hd() |> Caveat.to_map()

      assert is_binary(label)
      assert is_binary(body)
    end
  end
end
