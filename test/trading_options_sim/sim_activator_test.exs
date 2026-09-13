defmodule TradingOptionsSim.SimActivatorTest do
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.SimActivator

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

  describe "activate/1" do
    test "returns {:error, :no_target_pool} when the version has no pool" do
      version = version_fixture(%{})
      assert {:error, :no_target_pool} = SimActivator.activate(version)
    end

    test "returns {:error, :unsupported_leg_config} for an unrecognized selection method" do
      pool = pool_fixture(["AAPL"])

      version =
        version_fixture(%{
          target_pool_id: pool.id,
          option_leg_config: %{"strike_selection" => "fixed_delta"}
        })

      assert {:error, :unsupported_leg_config} = SimActivator.activate(version)
    end

    test "starts one monitor per pool member with fixed_strike selection" do
      pool = pool_fixture(["AAPLSA1", "MSFTSA1"])

      version =
        version_fixture(%{
          target_pool_id: pool.id,
          option_leg_config: fixed_leg_config()
        })

      assert {:ok, pids} = SimActivator.activate(version)
      assert length(pids) == 2
      assert Enum.all?(pids, &Process.alive?/1)

      open_runs = Sim.list_open_sim_runs(version)
      assert length(open_runs) == 2
      assert Enum.map(open_runs, & &1.symbol) |> Enum.sort() == ["AAPLSA1", "MSFTSA1"]
    end

    test "activating twice does not start a second monitor for the same contract" do
      pool = pool_fixture(["AAPLSA2"])

      version =
        version_fixture(%{
          target_pool_id: pool.id,
          option_leg_config: fixed_leg_config()
        })

      {:ok, [pid1]} = SimActivator.activate(version)
      {:ok, [pid2]} = SimActivator.activate(version)

      assert pid1 == pid2
      assert length(Sim.list_open_sim_runs(version)) == 1
    end

    test "started monitor is discoverable via ContractMonitor.whereis/2" do
      pool = pool_fixture(["AAPLSA3"])

      version =
        version_fixture(%{
          target_pool_id: pool.id,
          option_leg_config: fixed_leg_config()
        })

      {:ok, [pid]} = SimActivator.activate(version)

      [run] = Sim.list_open_sim_runs(version)
      contract_key = {run.symbol, run.expiry, run.strike, run.right}

      assert ContractMonitor.whereis(run.id, contract_key) == pid
    end
  end
end
