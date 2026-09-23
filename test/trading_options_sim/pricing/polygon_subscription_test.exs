defmodule TradingOptionsSim.Pricing.PolygonSubscriptionTest do
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.Pricing.PolygonSubscription

  # No HubClient in :test (start_hub_client: false), so every hub RPC
  # fails closed with :hub_unreachable. Deliberate rather than a
  # limitation: what matters most is that a failed subscribe never stops
  # a caller proceeding, and the refcount lifecycle is independent of
  # the RPC result.

  defp unique_symbol, do: "PGSUB#{System.unique_integer([:positive])}"

  describe "ensure/2 and release/1" do
    test "starts one holder per symbol and reports the outcome" do
      symbol = unique_symbol()

      assert PolygonSubscription.whereis(symbol) == nil
      assert {:ok, priced?} = PolygonSubscription.ensure(symbol)

      refute priced?
      assert is_pid(PolygonSubscription.whereis(symbol))

      PolygonSubscription.release(symbol)
    end

    test "a second ensure/2 reuses the same holder" do
      symbol = unique_symbol()

      {:ok, _} = PolygonSubscription.ensure(symbol)
      first = PolygonSubscription.whereis(symbol)

      {:ok, _} = PolygonSubscription.ensure(symbol)
      assert PolygonSubscription.whereis(symbol) == first

      PolygonSubscription.release(symbol)
      PolygonSubscription.release(symbol)
    end

    # The load-bearing one. Several strategies on a symbol share a
    # subscription, and the FIRST to release must not tear it down --
    # the bug trading_live hit where one monitor's unsubscribe killed
    # another still-live monitor's feed.
    test "the holder survives until the LAST dependant releases" do
      symbol = unique_symbol()

      {:ok, _} = PolygonSubscription.ensure(symbol)
      {:ok, _} = PolygonSubscription.ensure(symbol)
      pid = PolygonSubscription.whereis(symbol)

      PolygonSubscription.release(symbol)
      assert Process.alive?(pid), "first release must not stop a holder with 2 dependants"

      PolygonSubscription.release(symbol)
      refute_eventually_alive(pid)
    end

    test "release/1 on an unknown or already-stopped symbol is a no-op" do
      assert PolygonSubscription.release(unique_symbol()) == :ok

      symbol = unique_symbol()
      {:ok, _} = PolygonSubscription.ensure(symbol)
      PolygonSubscription.release(symbol)
      assert PolygonSubscription.release(symbol) == :ok
    end

    test "ensure/2 returns promptly when no tick can arrive" do
      symbol = unique_symbol()

      {elapsed_us, {:ok, priced?}} = :timer.tc(fn -> PolygonSubscription.ensure(symbol) end)

      refute priced?
      assert elapsed_us < 1_000_000, "ensure/2 took #{div(elapsed_us, 1000)}ms; must be bounded"

      PolygonSubscription.release(symbol)
    end
  end

  describe "recovery" do
    test "re-subscribes on :nodeup for the hub node" do
      symbol = unique_symbol()
      {:ok, _} = PolygonSubscription.ensure(symbol)
      pid = PolygonSubscription.whereis(symbol)

      assert PolygonSubscription.stats(pid).resubscribe_count == 0

      send(pid, {:nodeup, Application.fetch_env!(:trading_options_sim, :hub_node)})

      # Asserts the handler RAN, not merely that the process survived.
      assert PolygonSubscription.stats(pid).resubscribe_count == 1

      PolygonSubscription.release(symbol)
    end

    test "ignores :nodeup for any other node" do
      symbol = unique_symbol()
      {:ok, _} = PolygonSubscription.ensure(symbol)
      pid = PolygonSubscription.whereis(symbol)

      send(pid, {:nodeup, :elsewhere@nowhere})
      send(pid, {:nodedown, :elsewhere@nowhere})

      assert PolygonSubscription.stats(pid).resubscribe_count == 0
      assert Process.alive?(pid)

      PolygonSubscription.release(symbol)
    end

    # Polygon's websocket can clear its refcounts while the hub NODE
    # stays up, so :nodeup never fires for it. This is the trigger that
    # covers that case.
    test "re-subscribes on a polygon_websocket resubscribe broadcast" do
      symbol = unique_symbol()
      {:ok, _} = PolygonSubscription.ensure(symbol)
      pid = PolygonSubscription.whereis(symbol)

      send(pid, %{type: :health, data: %{component: :polygon_websocket, action: :resubscribe}})

      assert PolygonSubscription.stats(pid).resubscribe_count == 1

      PolygonSubscription.release(symbol)
    end

    # The hub drops its own refcount on a rejection, so we are no longer
    # subscribed. :sys.replace_state stands in for a successful subscribe,
    # which :test cannot produce (no hub).
    test "a subscribe_rejected for this symbol clears subscribed?" do
      symbol = unique_symbol()
      {:ok, _} = PolygonSubscription.ensure(symbol)
      pid = PolygonSubscription.whereis(symbol)
      :sys.replace_state(pid, &%{&1 | subscribed?: true})

      send(pid, rejected(unique_symbol()))
      assert PolygonSubscription.stats(pid).subscribed? == true

      send(pid, rejected(symbol))
      assert PolygonSubscription.stats(pid).subscribed? == false

      PolygonSubscription.release(symbol)
    end

    test "survives unrelated health broadcasts and arbitrary messages" do
      symbol = unique_symbol()
      {:ok, _} = PolygonSubscription.ensure(symbol)
      pid = PolygonSubscription.whereis(symbol)

      send(pid, %{type: :health, data: %{component: :ibkr, action: :connected}})
      send(pid, :some_atom)
      send(pid, {:tuple, :nobody, :handles})

      assert PolygonSubscription.stats(pid).resubscribe_count == 0
      assert Process.alive?(pid)

      PolygonSubscription.release(symbol)
    end
  end

  defp rejected(symbol) do
    %{
      type: :health,
      data: %{
        component: :polygon_websocket,
        status: :subscribe_rejected,
        action: :subscription_dropped,
        symbol: symbol
      }
    }
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
