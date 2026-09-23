defmodule TradingOptionsSim.ContractSelectorTest do
  use ExUnit.Case, async: true

  alias TradingOptionsSim.ContractSelector

  @feb "20270219"
  @mar "20270319"
  @apr "20270416"

  describe "third_friday_on_or_after/2" do
    test "120 DTE from 2026-09-23 lands on Feb 2027's third Friday" do
      assert ContractSelector.third_friday_on_or_after(~D[2026-09-23], 120) == @feb
    end

    test "one day after a third Friday is the next month's" do
      assert ContractSelector.third_friday_on_or_after(~D[2027-02-19], 1) == @mar
    end
  end

  describe "candidates/3" do
    test "rounded strike on every expiry first, then neighbours on the first" do
      assert ContractSelector.candidates("SPY", 768.0, [@feb, @mar, @apr]) == [
               {@feb, 770.0},
               {@mar, 770.0},
               {@apr, 770.0},
               {@feb, 775.0},
               {@feb, 765.0}
             ]
    end

    test "a single expiry keeps the original three-strike probe" do
      assert ContractSelector.candidates("QQQ", 744.0, [@feb]) ==
               [{@feb, 745.0}, {@feb, 750.0}, {@feb, 740.0}]
    end
  end

  describe "first_listed/4" do
    # Regression, 2026-09-23: SPY listed Jan and Mar 2027 but not Feb, so
    # every 120-DTE SPY leg failed with :no_listed_contract.
    test "falls through an unlisted month to the next listed one" do
      resolver = fn "SPY", expiry, _strike, "C" ->
        if expiry == @feb, do: {:error, :not_found}, else: {:ok, 1}
      end

      candidates = ContractSelector.candidates("SPY", 768.0, [@feb, @mar, @apr])

      assert {:ok, %{expiry: @mar, right: "C", strike: strike}} =
               ContractSelector.first_listed(candidates, "SPY", "C", resolver)

      assert Decimal.equal?(strike, Decimal.new("770.00"))
    end

    # The fall-through must not change behaviour when the target month
    # is listed: the first probe hits and nothing later is tried.
    test "a listed target month is used, not a later one" do
      resolver = fn _s, _e, _k, _r -> {:ok, 1} end
      candidates = ContractSelector.candidates("SPY", 768.0, [@feb, @mar, @apr])

      assert {:ok, %{expiry: @feb}} =
               ContractSelector.first_listed(candidates, "SPY", "C", resolver)
    end

    test "nothing listed anywhere is :no_listed_contract" do
      resolver = fn _s, _e, _k, _r -> {:error, :not_found} end
      candidates = ContractSelector.candidates("SPY", 768.0, [@feb, @mar, @apr])

      assert ContractSelector.first_listed(candidates, "SPY", "C", resolver) ==
               {:error, :no_listed_contract}
    end
  end
end
