defmodule TradingOptionsSim.Sim.Workers.PerformanceSnapshotWorkerTest do
  use TradingOptionsSim.DataCase, async: true

  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.Workers.PerformanceSnapshotWorker

  defp strategy_fixture do
    {:ok, strategy} = Sim.create_strategy(%{name: "Test Strategy"})
    strategy
  end

  defp version_fixture(strategy, attrs \\ %{}) do
    {:ok, version} =
      Sim.create_strategy_version(
        strategy,
        Map.merge(%{version: 1, position_sizing: %{"method" => "fixed_qty", "qty" => 1}}, attrs)
      )

    version
  end

  defp closed_run_fixture(version, symbol, at) do
    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: symbol,
        expiry: "20271231",
        strike: Decimal.new("150.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

    {:ok, {_fill, run}} =
      Sim.record_entry_fill(
        run,
        %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: at},
        %{entry_at: at, entry_price: Decimal.new("5.00")}
      )

    {:ok, {_fill, run}} =
      Sim.record_exit_fill(
        run,
        %{action: "sell", quantity: 1, fill_price: Decimal.new("6.00"), filled_at: at},
        %{
          exit_at: at,
          exit_price: Decimal.new("6.00"),
          exit_reason: "target_hit",
          realized_pnl: Decimal.new("100.00")
        }
      )

    run
  end

  defp set_activated_at(version, activated_at) do
    version
    |> Ecto.Changeset.change(activated_at: activated_at)
    |> TradingOptionsSim.Repo.update!()
  end

  test "perform/1 snapshots every version with a closed run and returns :ok" do
    strategy = strategy_fixture()
    version = version_fixture(strategy)
    closed_run_fixture(version, "WORKERTEST1", DateTime.utc_now())

    assert :ok = PerformanceSnapshotWorker.perform(%Oban.Job{})
    assert [_snapshot] = Sim.list_performance_snapshots(version)
  end

  # The gate must stay quiet on a normal day: versions that never
  # traded are ordinary skips, not misses.
  test "perform/1 returns :ok when the only skipped versions never traded" do
    strategy = strategy_fixture()
    traded = version_fixture(strategy)
    _untraded = version_fixture(strategy, %{version: 2})
    closed_run_fixture(traded, "WORKERTEST2", DateTime.utc_now())

    assert :ok = PerformanceSnapshotWorker.perform(%Oban.Job{})
    assert [_snapshot] = Sim.list_performance_snapshots(traded)
  end

  # The 2026-09-29 incident: a restart moved activated_at past today's
  # exits, so a version that traded got skipped and the job still
  # reported success.
  test "perform/1 cancels when a version that traded today got no snapshot" do
    strategy = strategy_fixture()
    version = version_fixture(strategy)
    closed_run_fixture(version, "WORKERTEST3", DateTime.add(DateTime.utc_now(), -3600, :second))

    set_activated_at(
      version,
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    )

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:cancel, reason} = PerformanceSnapshotWorker.perform(%Oban.Job{})
      assert reason =~ "1 version(s)"
    end)

    assert Sim.list_performance_snapshots(version) == []
  end

  # A deliberate deactivate + re-activate later the same day is not a
  # miss: the earlier runs belong to the previous activation.
  test "perform/1 returns :ok for a version deactivated and re-activated today" do
    strategy = strategy_fixture()
    version = version_fixture(strategy)
    closed_run_fixture(version, "WORKERTEST4", DateTime.add(DateTime.utc_now(), -3600, :second))

    {:ok, flat_run} =
      Sim.open_sim_run(version, %{
        symbol: "WORKERTEST4",
        expiry: "20271231",
        strike: Decimal.new("150.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

    {:ok, _closed} = Sim.close_run_without_entry(flat_run, "manual_no_entry")

    # Re-activated after the deactivation, so both closes fall before
    # the new window and the version is skipped.
    set_activated_at(
      version,
      DateTime.utc_now() |> DateTime.add(2, :second) |> DateTime.truncate(:second)
    )

    assert :ok = PerformanceSnapshotWorker.perform(%Oban.Job{})
    assert Sim.list_performance_snapshots(version) == []
  end
end
