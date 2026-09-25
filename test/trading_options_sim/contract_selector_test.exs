defmodule TradingOptionsSim.ContractSelectorTest do
  use ExUnit.Case, async: true

  # The pure half -- expiries, strike grid, probe order -- is
  # TradingCore.Options.ContractSelection and is tested in trading_core.
  # What this module owns is probing that list against IBKR in order, so
  # these tests run the real trading_core candidates through first_listed/3
  # with a stubbed resolver.

  alias TradingCore.Options.ContractSelection
  alias TradingOptionsSim.ContractSelector

  @atm_45 %{
    "strike_selection" => "atm_offset",
    "strike_offset" => 0,
    "expiry_selection" => "dte_target",
    "dte_target" => 45,
    "right" => "C"
  }

  # 120 DTE from 2026-09-23 targets Feb 2027's third Friday.
  @atm_120 %{@atm_45 | "dte_target" => 120}

  defp candidates(config, spot \\ 768.0),
    do: ContractSelection.candidates("SPY", config, spot, ~D[2026-09-23])

  test "uses trading_core's probe list: rounded strike on each expiry, then neighbours" do
    {:ok, list} = candidates(@atm_120)

    assert Enum.map(list, &{&1.expiry, &1.strike}) == [
             {"20270219", 770.0},
             {"20270319", 770.0},
             {"20270416", 770.0},
             {"20270219", 775.0},
             {"20270219", 765.0}
           ]
  end

  # Regression, 2026-09-23: SPY listed Jan and Mar 2027 but not Feb, so
  # every 120-DTE SPY leg failed with :no_listed_contract.
  test "falls through an unlisted month to the next listed one" do
    {:ok, list} = candidates(@atm_120)

    resolver = fn "SPY", expiry, _strike, "C" ->
      if expiry == "20270219", do: {:error, :not_found}, else: {:ok, 1}
    end

    assert {:ok, %{expiry: "20270319", right: "C", strike: strike}} =
             ContractSelector.first_listed(list, "SPY", resolver)

    assert Decimal.equal?(strike, Decimal.new("770.00"))
  end

  test "a listed target month is used, not a later one" do
    {:ok, list} = candidates(@atm_45)
    resolver = fn _s, _e, _k, _r -> {:ok, 1} end

    assert {:ok, %{expiry: expiry}} = ContractSelector.first_listed(list, "SPY", resolver)
    assert expiry == hd(list).expiry
  end

  test "probes in order and stops at the first listed contract" do
    {:ok, list} = candidates(@atm_120)
    test_pid = self()

    resolver = fn _s, expiry, strike, _r ->
      send(test_pid, {:probed, expiry, strike})
      if expiry == "20270416", do: {:ok, 1}, else: {:error, :not_found}
    end

    assert {:ok, %{expiry: "20270416"}} = ContractSelector.first_listed(list, "SPY", resolver)

    assert_received {:probed, "20270219", 770.0}
    assert_received {:probed, "20270319", 770.0}
    assert_received {:probed, "20270416", 770.0}
    # Stopped: the neighbours were never probed.
    refute_received {:probed, _, 775.0}
  end

  # 2026-09-24: a busy restart timed out probes for a LISTED contract and
  # the member was skipped for good. An unanswered probe is not a "no".
  test "an unanswered probe stops with :hub_unavailable, not :no_listed_contract" do
    {:ok, list} = candidates(@atm_120)
    test_pid = self()

    resolver = fn _s, expiry, strike, _r ->
      send(test_pid, {:probed, expiry, strike})
      if expiry == "20270219", do: {:error, :not_found}, else: {:error, :hub_unreachable}
    end

    assert ContractSelector.first_listed(list, "SPY", resolver) == {:error, :hub_unavailable}

    # Stopped at the first unanswered probe instead of piling on.
    assert_received {:probed, "20270219", 770.0}
    assert_received {:probed, "20270319", 770.0}
    refute_received {:probed, "20270416", _}
  end

  test ":ambiguous is an answer, like :not_found, so probing continues" do
    {:ok, list} = candidates(@atm_120)

    resolver = fn _s, expiry, _k, _r ->
      if expiry == "20270219", do: {:error, :ambiguous}, else: {:ok, 1}
    end

    assert {:ok, %{expiry: "20270319"}} = ContractSelector.first_listed(list, "SPY", resolver)
  end

  test "nothing listed anywhere is :no_listed_contract" do
    {:ok, list} = candidates(@atm_120)
    resolver = fn _s, _e, _k, _r -> {:error, :not_found} end

    assert ContractSelector.first_listed(list, "SPY", resolver) == {:error, :no_listed_contract}
  end

  test "an unsupported leg config never reaches the hub" do
    assert ContractSelector.resolve("SPY", %{"strike_selection" => "fixed_delta"}) ==
             {:error, :unsupported_leg_config}
  end
end
