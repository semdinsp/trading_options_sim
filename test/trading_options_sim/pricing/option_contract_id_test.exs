defmodule TradingOptionsSim.Pricing.OptionContractIdTest do
  use ExUnit.Case, async: true

  alias TradingOptionsSim.Pricing.OptionContractId

  @resolver TradingHub.IBKR.ContractResolver

  # QQQ 261218P00710000: one of the strikes TWS rejected as ambiguous.
  defp contract do
    %{sec_type: "OPT", underlying_symbol: "QQQ", expiry: "20261218", strike: 710.0, right: "P"}
  end

  # A fake hub: `resolve5?` says whether resolve/5 is exported; `reply`
  # answers the resolve call. Each call is sent to the test process.
  defp hub(resolve5?, reply) do
    test = self()

    fn
      :erlang, :function_exported, [@resolver, :resolve, 5], _timeout ->
        resolve5?

      @resolver, :resolve, args, _timeout ->
        send(test, {:resolve, args})
        reply
    end
  end

  describe "a hub with resolve/5" do
    test "resolves with the standard class and pins contract_id, multiplier and trading_class" do
      assert {:ok, pinned} = OptionContractId.pin(contract(), hub(true, {:ok, 812_345}))

      assert_received {:resolve,
                       ["QQQ", "20261218", 710.0, "P", [multiplier: "100", trading_class: "QQQ"]]}

      assert pinned ==
               Map.merge(contract(), %{
                 contract_id: 812_345,
                 multiplier: "100",
                 trading_class: "QQQ"
               })
    end

    test "an ambiguous answer is an error, not a blind subscribe" do
      assert OptionContractId.pin(contract(), hub(true, {:error, :ambiguous})) ==
               {:error, :ambiguous}
    end

    for reason <- [:not_found, :not_connected, :rpc_failed] do
      test "#{reason} is an error" do
        assert OptionContractId.pin(contract(), hub(true, {:error, unquote(reason)})) ==
                 {:error, unquote(reason)}
      end
    end
  end

  describe "an older hub with only resolve/4" do
    test "a unique description is pinned to its con_id" do
      assert {:ok, pinned} = OptionContractId.pin(contract(), hub(false, {:ok, 9}))
      assert_received {:resolve, ["QQQ", "20261218", 710.0, "P"]}
      assert %{contract_id: 9, multiplier: "100", trading_class: "QQQ"} = pinned
    end

    test "an ambiguous description is still subscribed, with the multiplier and no contract_id" do
      assert {:ok, pinned} = OptionContractId.pin(contract(), hub(false, {:error, :ambiguous}))
      assert pinned == Map.put(contract(), :multiplier, "100")
    end

    test "not_connected is an error" do
      assert OptionContractId.pin(contract(), hub(false, {:error, :not_connected})) ==
               {:error, :not_connected}
    end
  end

  test "a contract that already has a contract_id is not looked up again" do
    pinned = Map.put(contract(), :contract_id, 5)
    no_hub = fn _, _, _, _ -> flunk("hub called") end
    assert OptionContractId.pin(pinned, no_hub) == {:ok, pinned}
  end

  test "a contract without an underlying is an error" do
    no_hub = fn _, _, _, _ -> flunk("hub called") end
    assert {:error, {:incomplete_contract, _}} = OptionContractId.pin(%{sec_type: "OPT"}, no_hub)
  end

  test "no more than 20 lookups are in flight at once" do
    {:ok, peak} = Agent.start_link(fn -> {0, 0} end)

    slow_hub = fn
      :erlang, :function_exported, _, _ ->
        true

      _, :resolve, _, _ ->
        Agent.update(peak, fn {now, max} -> {now + 1, max(max, now + 1)} end)
        Process.sleep(30)
        Agent.update(peak, fn {now, max} -> {now - 1, max} end)
        {:ok, 1}
    end

    1..60
    |> Task.async_stream(fn _ -> OptionContractId.pin(contract(), slow_hub) end,
      max_concurrency: 60,
      timeout: 10_000
    )
    |> Enum.each(fn {:ok, result} -> assert {:ok, %{contract_id: 1}} = result end)

    {_now, max} = Agent.get(peak, & &1)
    assert max <= 20
    assert max > 1
  end

  test "an unreachable hub is an error, not a crash" do
    assert {:error, _} = OptionContractId.pin(contract())
  end
end
