defmodule TradingOptionsSim.SimReactivatorTest do
  # async: false — starts real ContractMonitor processes under the
  # shared TradingOptionsSim.MonitorRegistry/MonitorSupervisor, same
  # isolation concern SimActivatorTest's own async: false already
  # documents.
  use TradingOptionsSim.DataCase, async: false

  # Deterministic replacement for Process.sleep/1 after a broadcast.
  # PubSub delivery is asynchronous, so sleeping bets that the monitor
  # finishes inside the interval; a GenServer.call cannot be served
  # until it has drained the broadcast ahead of it. Falls back to a
  # sleep only when no monitor is registered -- there is then nothing
  # to synchronise against. See contract_monitor_test.exs's sync/1.
  defp sync_monitor(version_id, symbol) do
    key = {symbol, "20271231", Decimal.new("150.00"), "C"}

    case TradingOptionsSim.ContractMonitor.whereis(version_id, key) do
      nil -> Process.sleep(50)
      pid -> _ = TradingOptionsSim.ContractMonitor.snapshot(pid)
    end

    :ok
  end

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.SimReactivator

  defp pool_fixture(symbols) do
    {:ok, pool} = Sim.create_target_pool(%{name: "Pool #{System.unique_integer([:positive])}"})

    Enum.each(symbols, fn symbol ->
      {:ok, _member} = Sim.add_target_pool_member(pool, %{symbol: symbol})
    end)

    Sim.get_target_pool!(pool.id)
  end

  defp fixed_leg_config do
    %{
      "expiry_selection" => "fixed",
      "fixed_expiry" => "20271231",
      "strike_selection" => "fixed_strike",
      "fixed_strike" => "150.00",
      "right" => "C"
    }
  end

  defp version_fixture(attrs) do
    {:ok, strategy} = Sim.create_strategy(%{name: "Test Strategy"})

    {:ok, version} =
      Sim.create_strategy_version(
        strategy,
        Map.merge(%{version: 1, position_sizing: %{"method" => "fixed_qty", "qty" => 1}}, attrs)
      )

    version
  end

  # Simulates the exact real-world scenario this module fixes: a
  # version that was activated (activated_at set — see that field's own
  # doc for why list_active_strategy_versions/0 keys off this, not "has
  # an open run") with a SimRun left "open" in the DB but no running
  # monitor — an app restart (crash, deploy, plain `mix phx.server`
  # restart) with nothing to repopulate MonitorSupervisor's
  # dynamically-started children. open_sim_run/2 directly (not
  # SimActivator.activate/1) so no monitor process is ever started for
  # it — matching a fresh boot's own state.
  defp orphaned_open_run_fixture(version, symbol) do
    {:ok, _version} = Sim.mark_activated(version)

    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: symbol,
        expiry: "20271231",
        strike: Decimal.new("150.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

    run
  end

  describe "retrying unanswered contract lookups" do
    # :test has no trading_hub, so an atm_offset member's spot lookup
    # goes unanswered -- exactly the transient failure a busy restart
    # produced on 2026-09-24. fixed_strike needs no lookup at all.
    setup do
      previous = Application.get_env(:trading_options_sim, :version_retry_base_ms)
      Application.put_env(:trading_options_sim, :version_retry_base_ms, 1)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:trading_options_sim, :version_retry_base_ms, previous),
          else: Application.delete_env(:trading_options_sim, :version_retry_base_ms)
      end)
    end

    defp atm_version(symbol) do
      pool = pool_fixture([symbol])

      version =
        version_fixture(%{
          target_pool_id: pool.id,
          option_leg_config: %{
            "strike_selection" => "atm_offset",
            "strike_offset" => 0,
            "expiry_selection" => "dte_target",
            "dte_target" => 45,
            "right" => "C"
          }
        })

      {:ok, version} = Sim.mark_activated(version)
      version
    end

    defp await_log(fun, pattern, timeout_ms \\ 3_000) do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          fun.()

          Enum.reduce_while(1..div(timeout_ms, 20), nil, fn _, _ ->
            Process.sleep(20)
            {:cont, nil}
          end)
        end)

      assert log =~ pattern
      log
    end

    test "activate_report/1 reports an unanswered lookup as transient" do
      version = atm_version("RETRY1")

      assert {:ok, [], [], ["RETRY1"]} = TradingOptionsSim.SimActivator.activate_report(version)
    end

    # Must NOT retry on healthy input: a member that resolves (here a
    # fixed_strike, which needs no lookup) is never reported transient.
    test "activate_report/1 reports nothing when every member resolves" do
      pool = pool_fixture(["RETRY2"])

      version =
        version_fixture(%{target_pool_id: pool.id, option_leg_config: fixed_leg_config()})

      assert {:ok, [_pid], [], []} = TradingOptionsSim.SimActivator.activate_report(version)
    end

    test "retries an unanswered version with backoff, then gives up" do
      version = atm_version("RETRY3")
      {:ok, pid} = SimReactivator.start_link()
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      await_log(
        fn -> SimReactivator.retry_later(version.id) end,
        "still unanswered after 5 retries"
      )
    end

    # Found in review: a version deleted before its retry fired used to
    # raise, be counted as unanswered, and be retried until giving up.
    test "a version that no longer exists is dropped, not retried" do
      {:ok, pid} = SimReactivator.start_link()
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          SimReactivator.retry_later(Ecto.UUID.generate())

          Enum.reduce_while(1..100, nil, fn _, _ ->
            if :sys.get_state(pid).pending == %{},
              do: {:halt, nil},
              else: Process.sleep(10) && {:cont, nil}
          end)
        end)

      assert :sys.get_state(pid).pending == %{}
      refute log =~ "still unanswered"
    end

    test "a version that resolves on retry is dropped after one attempt" do
      pool = pool_fixture(["RETRY4"])

      version =
        version_fixture(%{target_pool_id: pool.id, option_leg_config: fixed_leg_config()})

      {:ok, version} = Sim.mark_activated(version)
      {:ok, pid} = SimReactivator.start_link()
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          SimReactivator.retry_later(version.id)

          # The retry fires after 1ms; poll for its outcome rather than
          # sleeping a fixed time.
          Enum.reduce_while(1..150, nil, fn _, _ ->
            done? =
              TradingOptionsSim.ContractMonitor.monitors_for_version(version.id) != [] and
                :sys.get_state(pid).pending == %{}

            if done?, do: {:halt, nil}, else: Process.sleep(20) && {:cont, nil}
          end)
        end)

      assert [{"RETRY4", _pid}] =
               TradingOptionsSim.ContractMonitor.monitors_for_version(version.id)

      assert :sys.get_state(pid).pending == %{}
      refute log =~ "still unanswered"
    end
  end

  test "restarts monitors for every StrategyVersion with an open SimRun" do
    pool = pool_fixture(["REACTSYM1"])

    version =
      version_fixture(%{target_pool_id: pool.id, option_leg_config: fixed_leg_config()})

    run = orphaned_open_run_fixture(version, "REACTSYM1")
    contract_key = {run.symbol, run.expiry, run.strike, run.right}
    assert ContractMonitor.whereis(version.id, contract_key) == nil

    {:ok, pid} = SimReactivator.start_link()
    Process.sleep(50)

    assert Process.alive?(pid)
    assert is_pid(ContractMonitor.whereis(version.id, contract_key))

    GenServer.stop(pid)
  end

  # The exact production incident this module exists to fix (confirmed
  # live 2026-09-15, "Slope Long Calls v2"): a version was activated,
  # its position closed via a rule-triggered exit (no open SimRun left
  # at all — not "orphaned," genuinely flat), and the app restarted
  # minutes later. Before activated_at/deactivated_at existed,
  # SimReactivator's own Sim.list_active_strategy_versions/0 call found
  # nothing to reactivate (no open run = invisible), so the monitor
  # never came back despite the operator never deactivating the
  # strategy.
  test "restarts a monitor for an activated version with zero open runs (flat)" do
    pool = pool_fixture(["REACTSYM4"])

    version =
      version_fixture(%{
        target_pool_id: pool.id,
        option_leg_config: fixed_leg_config(),
        rules: %{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100},
          "exit" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 140}
        }
      })

    {:ok, [pid], []} = TradingOptionsSim.SimActivator.activate(version)

    # Enter, then let a real rule-triggered exit close the run — this is
    # the actual production sequence ("Slope Long Calls v2", confirmed
    # live 2026-09-15): a genuinely-closed run, not an orphaned
    # never-entered one (do_force_close/2 is a no-op when flat, so
    # killing the process alone would never produce this state).
    message = fn price ->
      %{type: :price, symbol: "REACTSYM4", source: :ibkr, data: %{last: price}}
      |> Map.put(:__struct__, TradingHub.Message)
    end

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:REACTSYM4", message.(130.0))
    sync_monitor(version.id, "REACTSYM4")
    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:REACTSYM4", message.(150.0))
    sync_monitor(version.id, "REACTSYM4")

    assert Sim.list_open_sim_runs(version) == []

    # Simulate the restart: kill the (now flat) monitor directly rather
    # than waiting for a real app boot.
    :ok = GenServer.stop(pid, :normal)
    Process.sleep(20)

    contract_key = {"REACTSYM4", "20271231", Decimal.new("150.00"), "C"}
    assert ContractMonitor.whereis(version.id, contract_key) == nil

    {:ok, reactivator_pid} = SimReactivator.start_link()
    Process.sleep(50)

    assert is_pid(ContractMonitor.whereis(version.id, contract_key))

    GenServer.stop(reactivator_pid)
  end

  test "does not start a second monitor for an already-running run" do
    pool = pool_fixture(["REACTSYM2"])

    version =
      version_fixture(%{target_pool_id: pool.id, option_leg_config: fixed_leg_config()})

    {:ok, [existing_pid], []} = TradingOptionsSim.SimActivator.activate(version)

    {:ok, pid} = SimReactivator.start_link()
    Process.sleep(50)

    [run] = Sim.list_open_sim_runs(version)
    contract_key = {run.symbol, run.expiry, run.strike, run.right}
    assert ContractMonitor.whereis(version.id, contract_key) == existing_pid

    GenServer.stop(pid)
  end

  test "is a no-op when nothing is currently active" do
    {:ok, pid} = SimReactivator.start_link()
    Process.sleep(50)

    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "re-reactivates when MonitorSupervisor goes down" do
    pool = pool_fixture(["REACTSYM3"])

    version =
      version_fixture(%{target_pool_id: pool.id, option_leg_config: fixed_leg_config()})

    run = orphaned_open_run_fixture(version, "REACTSYM3")
    contract_key = {run.symbol, run.expiry, run.strike, run.right}

    {:ok, pid} = SimReactivator.start_link()
    Process.sleep(50)
    assert is_pid(ContractMonitor.whereis(version.id, contract_key))

    # Simulate MonitorSupervisor crashing and restarting empty — send
    # the same :DOWN message SimReactivator's own Process.monitor/1
    # would deliver, without actually killing the shared supervisor
    # (other tests depend on it staying up).
    send(pid, {:DOWN, make_ref(), :process, self(), :simulated_crash})
    Process.sleep(50)

    assert Process.alive?(pid)
    assert is_pid(ContractMonitor.whereis(version.id, contract_key))

    GenServer.stop(pid)
  end
end
