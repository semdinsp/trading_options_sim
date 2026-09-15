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

      assert {:ok, pids, []} = SimActivator.activate(version)
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

      {:ok, [pid1], []} = SimActivator.activate(version)
      {:ok, [pid2], []} = SimActivator.activate(version)

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

      {:ok, [pid], []} = SimActivator.activate(version)

      [run] = Sim.list_open_sim_runs(version)
      contract_key = {run.symbol, run.expiry, run.strike, run.right}

      assert ContractMonitor.whereis(version.id, contract_key) == pid
    end

    test "sets activated_at and clears any prior deactivated_at" do
      pool = pool_fixture(["AAPLSA4"])

      version =
        version_fixture(%{target_pool_id: pool.id, option_leg_config: fixed_leg_config()})

      {:ok, _pids, []} = SimActivator.activate(version)
      {:ok, 1} = SimActivator.deactivate(version)

      {:ok, _pids, []} = SimActivator.activate(version)

      reloaded = Sim.get_strategy_version!(version.id)
      refute is_nil(reloaded.activated_at)
      assert is_nil(reloaded.deactivated_at)
    end

    test "an activated version appears in list_active_strategy_versions/0" do
      pool = pool_fixture(["AAPLSA5"])

      version =
        version_fixture(%{target_pool_id: pool.id, option_leg_config: fixed_leg_config()})

      {:ok, _pids, []} = SimActivator.activate(version)

      active_ids = Sim.list_active_strategy_versions() |> Enum.map(& &1.id)
      assert version.id in active_ids
    end
  end

  describe "deactivate/1" do
    test "terminates every running monitor and returns the count" do
      pool = pool_fixture(["AAPLSD1", "MSFTSD1"])

      version =
        version_fixture(%{
          target_pool_id: pool.id,
          option_leg_config: fixed_leg_config()
        })

      {:ok, pids, []} = SimActivator.activate(version)
      assert Enum.all?(pids, &Process.alive?/1)

      assert {:ok, 2} = SimActivator.deactivate(version)

      Process.sleep(20)
      refute Enum.any?(pids, &Process.alive?/1)
    end

    test "sets deactivated_at, leaves activated_at as history" do
      pool = pool_fixture(["AAPLSD6"])

      version =
        version_fixture(%{target_pool_id: pool.id, option_leg_config: fixed_leg_config()})

      {:ok, _pids, []} = SimActivator.activate(version)
      {:ok, _count} = SimActivator.deactivate(version)

      reloaded = Sim.get_strategy_version!(version.id)
      refute is_nil(reloaded.activated_at)
      refute is_nil(reloaded.deactivated_at)
    end

    test "a deactivated version no longer appears in list_active_strategy_versions/0" do
      pool = pool_fixture(["AAPLSD7"])

      version =
        version_fixture(%{target_pool_id: pool.id, option_leg_config: fixed_leg_config()})

      {:ok, _pids, []} = SimActivator.activate(version)
      {:ok, _count} = SimActivator.deactivate(version)

      active_ids = Sim.list_active_strategy_versions() |> Enum.map(& &1.id)
      refute version.id in active_ids
    end

    # The exact production incident this fixes (confirmed live
    # 2026-09-15, "Slope Long Calls v2"): a rule-triggered exit closes
    # the run while the monitor stays alive, flat, watching for the
    # next entry. Before this fix, deactivate/1 only ever looked up
    # monitors by open-run symbols, so a flat monitor with no open run
    # was invisible to it — deactivating left it running forever,
    # orphaned from the version's own now-"deactivated" DB state.
    test "stops a flat monitor with no open run (closed via a prior rule exit)" do
      pool = pool_fixture(["AAPLSD8"])

      version =
        version_fixture(%{
          target_pool_id: pool.id,
          option_leg_config: fixed_leg_config(),
          rules: %{
            "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100},
            "exit" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 140}
          }
        })

      {:ok, [pid], []} = SimActivator.activate(version)

      message = fn price ->
        %{type: :price, symbol: "AAPLSD8", source: :ibkr, data: %{last: price}}
        |> Map.put(:__struct__, TradingHub.Message)
      end

      Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:AAPLSD8", message.(130.0))
      Process.sleep(50)
      Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:AAPLSD8", message.(150.0))
      Process.sleep(50)

      assert Sim.list_open_sim_runs(version) == []
      assert Process.alive?(pid)

      assert {:ok, 1} = SimActivator.deactivate(version)

      Process.sleep(20)
      refute Process.alive?(pid)
    end

    test "flattens an open position before terminating the monitor" do
      pool = pool_fixture(["AAPLSD2"])

      version =
        version_fixture(%{
          target_pool_id: pool.id,
          option_leg_config: fixed_leg_config(),
          rules: %{"entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 1}}
        })

      {:ok, [pid], []} = SimActivator.activate(version)
      [run] = Sim.list_open_sim_runs(version)

      message =
        %{type: :price, symbol: "AAPLSD2", source: :ibkr, data: %{last: 150.0}}
        |> Map.put(:__struct__, TradingHub.Message)

      Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:AAPLSD2", message)
      Process.sleep(50)

      assert ContractMonitor.snapshot(pid).position_open? == true

      assert {:ok, 1} = SimActivator.deactivate(version)

      closed_run = Sim.get_sim_run!(run.id)
      assert closed_run.status == "closed"
      assert closed_run.exit_reason == "manual"
    end

    test "closes a never-entered run with exit_reason manual_no_entry, no fill recorded" do
      pool = pool_fixture(["AAPLSD5"])

      version =
        version_fixture(%{
          target_pool_id: pool.id,
          option_leg_config: fixed_leg_config()
        })

      {:ok, [pid], []} = SimActivator.activate(version)
      [run] = Sim.list_open_sim_runs(version)
      refute ContractMonitor.snapshot(pid).position_open?

      assert {:ok, 1} = SimActivator.deactivate(version)

      closed_run = Sim.get_sim_run!(run.id)
      assert closed_run.status == "closed"
      assert closed_run.exit_reason == "manual_no_entry"
      assert closed_run.entry_price == nil
      assert closed_run.exit_price == nil
      assert closed_run.realized_pnl == nil
      assert Sim.list_sim_fills(run) == []
    end

    test "does not change lifecycle_stage" do
      pool = pool_fixture(["AAPLSD3"])

      version =
        version_fixture(%{
          target_pool_id: pool.id,
          option_leg_config: fixed_leg_config()
        })

      {:ok, _pids, []} = SimActivator.activate(version)
      assert {:ok, 1} = SimActivator.deactivate(version)

      assert Sim.get_strategy_version!(version.id).lifecycle_stage == "discovery"
    end

    test "is a no-op for a version with no running monitors" do
      version = version_fixture(%{})
      assert {:ok, 0} = SimActivator.deactivate(version)
    end

    test "does not error on a run whose monitor already exited and was not restarted" do
      pool = pool_fixture(["AAPLSD4"])

      version =
        version_fixture(%{
          target_pool_id: pool.id,
          option_leg_config: fixed_leg_config()
        })

      {:ok, [pid], []} = SimActivator.activate(version)

      # :normal exit — the monitor's own :transient restart strategy only
      # restarts on an ABNORMAL exit (confirmed live: a :kill exit here
      # was silently restarted by the supervisor before deactivate/1 ran,
      # making this test accidentally exercise "monitor got replaced" —
      # a real, correct behavior, but not the "genuinely gone" case this
      # test means to cover), so this is the one exit reason guaranteed
      # to actually leave the registry entry empty.
      GenServer.stop(pid, :normal)
      Process.sleep(20)

      assert {:ok, 0} = SimActivator.deactivate(version)
    end
  end
end
