defmodule TradingOptionsSim.ContractListingCacheTest do
  # async: false -- the cache is one named table shared by the app.
  use ExUnit.Case, async: false

  alias TradingOptionsSim.{ContractListingCache, ContractSelector}

  setup do
    ContractListingCache.clear()
    on_exit(&ContractListingCache.clear/0)
  end

  # A resolver that counts its calls and answers from `answers`
  # (keyed by strike), like trading_hub's ContractResolver.
  defp counting_resolver(answers) do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    resolver = fn _symbol, _expiry, strike, _right ->
      Agent.update(calls, &(&1 + 1))
      Map.fetch!(answers, strike)
    end

    {resolver, fn -> Agent.get(calls, & &1) end}
  end

  test "ten versions probing the same unlisted strike ask the hub once" do
    {resolver, calls} = counting_resolver(%{62.0 => {:error, :not_found}, 63.0 => {:ok, 7}})
    cached = ContractListingCache.cached(resolver)

    candidates = [
      %{expiry: "20270115", strike: 62.0, right: "C"},
      %{expiry: "20270115", strike: 63.0, right: "C"}
    ]

    results = for _version <- 1..10, do: ContractSelector.first_listed(candidates, "XLE", cached)

    assert Enum.all?(results, &match?({:ok, %{strike: _}}, &1))
    # One miss for 62, cached; ten hits for 63 (hits are cached by the hub, not here).
    assert calls.() == 11
  end

  test "an ambiguous answer is cached like a miss" do
    {resolver, calls} = counting_resolver(%{710 => {:error, :ambiguous}})
    cached = ContractListingCache.cached(resolver)

    assert cached.("QQQ", "20261218", 710, "P") == {:error, :ambiguous}
    assert cached.("QQQ", "20261218", 710, "P") == {:error, :ambiguous}
    assert calls.() == 1
  end

  test "a hub that did not answer is asked again" do
    {resolver, calls} = counting_resolver(%{62 => {:error, :hub_unreachable}})
    cached = ContractListingCache.cached(resolver)

    cached.("XLE", "20270115", 62, "C")
    cached.("XLE", "20270115", 62, "C")
    assert calls.() == 2
  end

  test "62, 62.0 and Decimal 62.00 are one strike" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    resolver = fn _, _, _, _ ->
      Agent.update(calls, &(&1 + 1))
      {:error, :not_found}
    end

    cached = ContractListingCache.cached(resolver)

    for strike <- [62, 62.0, Decimal.new("62.00")], do: cached.("XLE", "20270115", strike, "C")
    assert Agent.get(calls, & &1) == 1
  end

  test "a different expiry or right is a different contract" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    resolver = fn _, _, _, _ ->
      Agent.update(calls, &(&1 + 1))
      {:error, :not_found}
    end

    cached = ContractListingCache.cached(resolver)
    cached.("XLE", "20270115", 62, "C")
    cached.("XLE", "20270219", 62, "C")
    cached.("XLE", "20270115", 62, "P")
    assert Agent.get(calls, & &1) == 3
  end

  test "an entry expires after the TTL" do
    Application.put_env(:trading_options_sim, :contract_listing_cache_ttl_ms, 0)

    on_exit(fn ->
      Application.delete_env(:trading_options_sim, :contract_listing_cache_ttl_ms)
    end)

    {resolver, calls} = counting_resolver(%{62 => {:error, :not_found}})
    cached = ContractListingCache.cached(resolver)

    cached.("XLE", "20270115", 62, "C")
    cached.("XLE", "20270115", 62, "C")
    assert calls.() == 2
  end
end
