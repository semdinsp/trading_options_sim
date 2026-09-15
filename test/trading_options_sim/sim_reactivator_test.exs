defmodule TradingOptionsSim.SimReactivatorTest do
  # async: false — starts real ContractMonitor processes under the
  # shared TradingOptionsSim.MonitorRegistry/MonitorSupervisor, same
  # isolation concern SimActivatorTest's own async: false already
  # documents.
  use TradingOptionsSim.DataCase, async: false

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

  # Simulates the exact real-world scenario this module fixes: a SimRun
  # left "open" in the DB with no running monitor — an app restart
  # (crash, deploy, plain `mix phx.server` restart) with nothing to
  # repopulate MonitorSupervisor's dynamically-started children.
  # open_sim_run/2 directly (not SimActivator.activate/1) so no monitor
  # process is ever started for it — matching a fresh boot's own state.
  defp orphaned_open_run_fixture(version, symbol) do
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
