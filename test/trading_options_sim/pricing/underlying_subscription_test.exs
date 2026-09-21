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

    # The first-tick wait must be bounded and must not raise when no tick
    # can ever arrive. config/test.exs sets the timeout to 0, so this
    # exercises the "gave up" path rather than the "tick arrived" one --
    # the failure mode that matters, since a hang here would stall an
    # entire activation sweep rather than skipping one symbol.
    test "ensure/2 returns promptly when no tick can arrive" do
      symbol = unique_symbol()

      {elapsed_us, {:ok, priced?}} =
        :timer.tc(fn -> UnderlyingSubscription.ensure(symbol) end)

      refute priced?
      assert elapsed_us < 1_000_000, "ensure/2 took #{div(elapsed_us, 1000)}ms; must be bounded"

      UnderlyingSubscription.release(symbol)
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

  describe "recovery after a hub-side subscription is lost" do
    # A hub restart clears trading_hub's refcounts but never touches this
    # process, so supervision does not repair it and init/1 never
    # re-runs. Meanwhile this app's PubSub registrations survive intact
    # -- so without these handlers the app stays subscribed to a topic
    # nobody publishes to, with no crash and no log line.

    test "re-subscribes on :nodeup for the hub node" do
      symbol = unique_symbol()
      {:ok, _} = UnderlyingSubscription.ensure(symbol)
      pid = UnderlyingSubscription.whereis(symbol)

      assert UnderlyingSubscription.stats(pid).resubscribe_count == 0

      send(pid, {:nodeup, Application.fetch_env!(:trading_options_sim, :hub_node)})

      # Asserts the handler RAN, not merely that the process survived
      # the message. Verified by sabotage: disabling the nodeup clause
      # leaves an "is it still alive" assertion passing, so only the
      # counter actually catches a broken handler.
      assert UnderlyingSubscription.stats(pid).resubscribe_count == 1

      UnderlyingSubscription.release(symbol)
      UnderlyingSubscription.release(symbol)
    end

    test "ignores :nodeup for any other node" do
      symbol = unique_symbol()
      {:ok, _} = UnderlyingSubscription.ensure(symbol)
      pid = UnderlyingSubscription.whereis(symbol)

      send(pid, {:nodeup, :some_other_node@nowhere})
      send(pid, {:nodedown, :some_other_node@nowhere})

      assert UnderlyingSubscription.stats(pid).resubscribe_count == 0,
             "an unrelated node event must not trigger a re-subscribe"

      assert Process.alive?(pid)

      UnderlyingSubscription.release(symbol)
      UnderlyingSubscription.release(symbol)
    end

    # The Polygon websocket can clear its refcounts while the hub NODE
    # stays up, so :nodeup never fires for it. Matched structurally as a
    # plain map to avoid a compile-time dependency on trading_hub.
    test "re-subscribes on a polygon_websocket resubscribe health broadcast" do
      symbol = unique_symbol()
      {:ok, _} = UnderlyingSubscription.ensure(symbol)
      pid = UnderlyingSubscription.whereis(symbol)

      send(pid, %{
        type: :health,
        data: %{component: :polygon_websocket, action: :resubscribe}
      })

      assert UnderlyingSubscription.stats(pid).resubscribe_count == 1

      UnderlyingSubscription.release(symbol)
      UnderlyingSubscription.release(symbol)
    end

    # This process subscribes to "system:health", a topic it does not
    # own, so it WILL receive broadcasts it has no specific clause for.
    # trading_system hit exactly this: its connection GenServer took
    # "account:equity" broadcasts and crashed with FunctionClauseError
    # on every reconnect.
    test "survives unrelated health broadcasts and arbitrary messages" do
      symbol = unique_symbol()
      {:ok, _} = UnderlyingSubscription.ensure(symbol)
      pid = UnderlyingSubscription.whereis(symbol)

      send(pid, %{type: :health, data: %{component: :ibkr, action: :connected}})
      send(pid, %{type: :price, symbol: "SPY", data: %{last: 100.0}})
      send(pid, :some_unexpected_atom)
      send(pid, {:tuple, :nobody, :handles})

      assert UnderlyingSubscription.stats(pid).resubscribe_count == 0,
             "unrelated messages must not trigger a re-subscribe"

      assert Process.alive?(pid)

      UnderlyingSubscription.release(symbol)
      UnderlyingSubscription.release(symbol)
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
