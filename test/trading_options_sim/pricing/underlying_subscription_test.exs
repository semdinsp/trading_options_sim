defmodule TradingOptionsSim.Pricing.UnderlyingSubscriptionTest do
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.Pricing.UnderlyingSubscription

  # There is no HubClient in :test (config/test.exs sets
  # start_hub_client: false), so every hub RPC here fails closed with
  # :hub_unreachable. That is deliberate rather than a limitation: the
  # behaviour that matters most is what happens when trading_hub is NOT
  # reachable, because a subscribe failure must never stop a strategy
  # activating. The refcount lifecycle is independent of the RPC result,
  # which is exactly what these tests pin down.

  defp unique_symbol, do: "UNDSUB#{System.unique_integer([:positive])}"

  describe "ensure/2 and release/1" do
    test "starts one holder per symbol and reports the subscribe outcome" do
      symbol = unique_symbol()

      assert UnderlyingSubscription.whereis(symbol) == nil
      assert {:ok, subscribed?} = UnderlyingSubscription.ensure(symbol)

      # false here because no hub is reachable in :test. The point is
      # that ensure/2 still succeeds and the holder still runs.
      refute subscribed?
      assert is_pid(UnderlyingSubscription.whereis(symbol))

      UnderlyingSubscription.release(symbol)
    end

    test "a second ensure/2 reuses the same holder rather than starting another" do
      symbol = unique_symbol()

      {:ok, _} = UnderlyingSubscription.ensure(symbol)
      first = UnderlyingSubscription.whereis(symbol)

      {:ok, _} = UnderlyingSubscription.ensure(symbol)
      assert UnderlyingSubscription.whereis(symbol) == first

      UnderlyingSubscription.release(symbol)
      UnderlyingSubscription.release(symbol)
    end

    # The load-bearing test. Two strategies on one underlying share a
    # subscription, and the FIRST to release must not tear it down --
    # that is the exact bug trading_live hit and documented, where one
    # monitor's unsubscribe killed another still-live monitor's feed.
    test "the holder survives until the LAST dependant releases" do
      symbol = unique_symbol()

      {:ok, _} = UnderlyingSubscription.ensure(symbol)
      {:ok, _} = UnderlyingSubscription.ensure(symbol)
      pid = UnderlyingSubscription.whereis(symbol)

      UnderlyingSubscription.release(symbol)
      assert Process.alive?(pid), "first release must not stop a holder with 2 dependants"
      assert UnderlyingSubscription.whereis(symbol) == pid

      UnderlyingSubscription.release(symbol)
      refute_eventually_alive(pid)
      refute_eventually_registered(symbol)
    end

    test "release/1 on an unknown or already-stopped symbol is a no-op" do
      assert UnderlyingSubscription.release(unique_symbol()) == :ok

      symbol = unique_symbol()
      {:ok, _} = UnderlyingSubscription.ensure(symbol)
      UnderlyingSubscription.release(symbol)

      # Releasing again must not raise -- a monitor terminating after the
      # holder already stopped is an ordinary race, not an error.
      assert UnderlyingSubscription.release(symbol) == :ok
    end

    test "holders for different symbols are independent" do
      a = unique_symbol()
      b = unique_symbol()

      {:ok, _} = UnderlyingSubscription.ensure(a)
      {:ok, _} = UnderlyingSubscription.ensure(b)

      pid_b = UnderlyingSubscription.whereis(b)
      UnderlyingSubscription.release(a)

      assert Process.alive?(pid_b)
      assert UnderlyingSubscription.whereis(b) == pid_b

      UnderlyingSubscription.release(b)
    end
  end

  # Registry cleanup is asynchronous: the entry is removed by the
  # Registry process reacting to the holder's DOWN, so it can briefly
  # outlive Process.alive?/1 returning false. Polling rather than
  # asserting once -- an earlier version checked immediately after the
  # process died and failed only under full-suite load, which is the
  # worst kind of flake.
  defp refute_eventually_registered(symbol) do
    Enum.reduce_while(1..100, nil, fn _i, _acc ->
      case UnderlyingSubscription.whereis(symbol) do
        nil -> {:halt, :unregistered}
        _pid -> Process.sleep(5) && {:cont, nil}
      end
    end) || flunk("#{symbol} still registered after its holder stopped")
  end

  defp refute_eventually_alive(pid) do
    Enum.reduce_while(1..100, nil, fn _i, _acc ->
      if Process.alive?(pid) do
        Process.sleep(5)
        {:cont, nil}
      else
        {:halt, :stopped}
      end
    end) || flunk("holder #{inspect(pid)} never stopped after its last release")
  end
end
