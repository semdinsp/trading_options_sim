defmodule TradingOptionsSim.Pricing.HubLineSweepTest do
  # async: false -- registers fake listeners in the shared MonitorRegistry.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias TradingOptionsSim.Pricing.{HubLineSweep, IBKRLive}

  @held "SPY   270115P00675000"
  @orphan "QQQ   270115C00680000"
  @other_app "XLE   270115P00058000"

  # A fake trading_hub: get_subscriptions returns `symbols`, and every
  # call is recorded so tests can assert what was released.
  defp fake_hub(symbols) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    call = fn function, args, _timeout ->
      Agent.update(agent, &[{function, args} | &1])

      case function do
        :get_subscriptions -> {:ok, symbols}
        :unsubscribe_symbol -> {:ok, :ok}
      end
    end

    {call, fn -> agent |> Agent.get(& &1) |> Enum.reverse() end}
  end

  defp unsubscribed(calls), do: for({:unsubscribe_symbol, [occ, tag]} <- calls, do: {occ, tag})

  # Stands in for a running IBKRLive listener: registers the listener's
  # name and stays alive until the test ends.
  defp fake_listener(occ) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(TradingOptionsSim.MonitorRegistry, {:ibkr_live, occ}, nil)
        send(test, :registered)
        receive do: (:stop -> :ok)
      end)

    assert_receive :registered
    on_exit(fn -> send(pid, :stop) end)
    pid
  end

  test "releases this app's tag only on option lines no local listener holds" do
    fake_listener(@held)
    {call, calls} = fake_hub([@held, @orphan, @other_app, "SPY", "QQQ"])

    assert {:ok, released} = HubLineSweep.release_orphans(call_hub: call)
    assert Enum.sort(released) == Enum.sort([@orphan, @other_app])

    assert Enum.sort(unsubscribed(calls.())) ==
             Enum.sort([
               {@orphan, IBKRLive.caller_tag(@orphan)},
               {@other_app, IBKRLive.caller_tag(@other_app)}
             ])

    # Never the bare symbol (another app's tag could be the OCC string),
    # never an underlying, never a held line.
    refute Enum.any?(unsubscribed(calls.()), fn {occ, tag} -> occ == @held or tag == occ end)
  end

  test "a healthy hub with every line held releases nothing" do
    fake_listener(@held)
    {call, calls} = fake_hub([@held, "SPY"])

    capture_log(fn -> assert {:ok, []} = HubLineSweep.release_orphans(call_hub: call) end)
    assert unsubscribed(calls.()) == []
  end

  test "an unanswered subscription list releases nothing" do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    call = fn function, args, _ ->
      Agent.update(agent, &[{function, args} | &1])
      {:error, :timeout}
    end

    log = capture_log(fn -> assert {:error, _} = HubLineSweep.release_orphans(call_hub: call) end)

    assert Agent.get(agent, & &1) == [{:get_subscriptions, []}]
    assert log =~ "could not list trading_hub subscriptions"
  end

  test "an unreachable hub client is caught" do
    call = fn _, _, _ -> exit({:noproc, :hub_client}) end

    log = capture_log(fn -> assert {:error, _} = HubLineSweep.release_orphans(call_hub: call) end)
    assert log =~ "trading_hub unreachable"
  end

  # The race the line lock closes: a listener for an orphan-looking
  # contract starts while the sweep runs. It registers, then subscribes
  # under the lock; the sweep re-checks under the same lock and skips it.
  test "a listener that starts mid-sweep keeps its line" do
    {call, calls} = fake_hub([@orphan])
    test = self()

    holder =
      spawn(fn ->
        IBKRLive.with_line_lock(@orphan, fn ->
          send(test, :locked)
          receive do: (:register -> :ok)

          {:ok, _} =
            Registry.register(TradingOptionsSim.MonitorRegistry, {:ibkr_live, @orphan}, nil)
        end)

        send(test, :unlocked)
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> send(holder, :stop) end)
    assert_receive :locked

    sweep =
      Task.async(fn -> capture_log(fn -> HubLineSweep.release_orphans(call_hub: call) end) end)

    # The sweep listed the line while no listener was registered, and now
    # waits on the lock.
    Process.sleep(50)
    send(holder, :register)
    assert_receive :unlocked

    Task.await(sweep)
    assert unsubscribed(calls.()) == []
  end

  test "option_symbol?/1 matches OCC symbols only" do
    assert HubLineSweep.option_symbol?("SPY   270115P00675000")
    assert HubLineSweep.option_symbol?("W     270115P00100000")
    assert HubLineSweep.option_symbol?("GOOGL 270115P00270000")
    refute HubLineSweep.option_symbol?("SPY")
    refute HubLineSweep.option_symbol?("ES-FUT-202612")
    refute HubLineSweep.option_symbol?(nil)
  end
end
