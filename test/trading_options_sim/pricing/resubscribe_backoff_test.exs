defmodule TradingOptionsSim.Pricing.ResubscribeBackoffTest do
  # async: false -- the retry tests change :resubscribe_retry_base_ms.
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.Pricing.{IBKRLive, ResubscribeBackoff, UnderlyingSubscription}

  defp with_base(ms) do
    previous = Application.get_env(:trading_options_sim, :resubscribe_retry_base_ms)
    Application.put_env(:trading_options_sim, :resubscribe_retry_base_ms, ms)

    on_exit(fn ->
      Application.put_env(:trading_options_sim, :resubscribe_retry_base_ms, previous)
    end)
  end

  defp state(subscribed?), do: %{subscribed?: subscribed?, retry_attempt: 0, retry_timer: nil}

  describe "after_attempt/1" do
    test "a failure schedules one retry; a second failure while pending adds none" do
      with_base(5)
      s = ResubscribeBackoff.after_attempt(state(false))
      assert s.retry_attempt == 1 and is_reference(s.retry_timer)

      assert ResubscribeBackoff.after_attempt(s) == s
      assert_receive :retry_subscribe, 500
      refute_receive :retry_subscribe, 50
    end

    # Must not fire on healthy input: a successful subscribe schedules
    # nothing, and cancels a pending retry.
    test "success clears the retry state and cancels a pending timer" do
      with_base(200)
      pending = ResubscribeBackoff.after_attempt(state(false))
      s = ResubscribeBackoff.after_attempt(%{pending | subscribed?: true})

      assert s.retry_attempt == 0 and s.retry_timer == nil
      refute_receive :retry_subscribe, 400
    end

    test "delay doubles from the base and caps at 60s" do
      with_base(2_000)

      assert Enum.map(1..7, &ResubscribeBackoff.delay_ms/1) ==
               [2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000]

      assert ResubscribeBackoff.delay_ms(500) == 60_000
    end
  end

  # :test has no trading_hub, so every subscribe fails -- the same state
  # as a restarted hub not yet taking subscriptions.
  describe "holders keep retrying until the hub accepts" do
    test "IBKRLive retries a failed subscribe with backoff" do
      with_base(5)
      pid = start_supervised!({IBKRLive, occ_symbol: "RETRYOCC1", contract: %{sec_type: "OPT"}})

      Enum.reduce_while(1..100, nil, fn _, _ ->
        if :sys.get_state(pid).resubscribe_count >= 2,
          do: {:halt, nil},
          else: Process.sleep(10) && {:cont, nil}
      end)

      assert :sys.get_state(pid).resubscribe_count >= 2
    end

    # The 2026-09-25 gap: IBKRLive had no :nodeup handling at all.
    test "IBKRLive re-subscribes when the hub node comes back" do
      pid = start_supervised!({IBKRLive, occ_symbol: "RETRYOCC2", contract: %{sec_type: "OPT"}})
      assert :sys.get_state(pid).resubscribe_count == 0

      send(pid, {:nodeup, Application.fetch_env!(:trading_options_sim, :hub_node)})
      assert :sys.get_state(pid).resubscribe_count == 1

      send(pid, {:nodeup, :some_other_node@nowhere})
      assert :sys.get_state(pid).resubscribe_count == 1
    end

    test "UnderlyingSubscription retries after a failed :nodeup re-subscribe" do
      with_base(5)
      {:ok, _} = UnderlyingSubscription.ensure("RETRYUND1")
      pid = UnderlyingSubscription.whereis("RETRYUND1")

      Enum.reduce_while(1..100, nil, fn _, _ ->
        if UnderlyingSubscription.stats(pid).resubscribe_count >= 2,
          do: {:halt, nil},
          else: Process.sleep(10) && {:cont, nil}
      end)

      assert UnderlyingSubscription.stats(pid).resubscribe_count >= 2
      UnderlyingSubscription.release("RETRYUND1")
    end
  end
end
