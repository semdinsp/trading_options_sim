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

  test "perform/1 snapshots every version with a closed run and returns :ok" do
    strategy = strategy_fixture()
    version = version_fixture(strategy)

    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: "WORKERTEST1",
        expiry: "20271231",
        strike: Decimal.new("150.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

    now = DateTime.utc_now()

    {:ok, {_fill, run}} =
      Sim.record_entry_fill(
        run,
        %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: now},
        %{entry_at: now, entry_price: Decimal.new("5.00")}
      )

    {:ok, {_fill, _run}} =
      Sim.record_exit_fill(
        run,
        %{action: "sell", quantity: 1, fill_price: Decimal.new("6.00"), filled_at: now},
        %{
          exit_at: now,
          exit_price: Decimal.new("6.00"),
          exit_reason: "target_hit",
          realized_pnl: Decimal.new("100.00")
        }
      )

    assert :ok = PerformanceSnapshotWorker.perform(%Oban.Job{})
    assert [_snapshot] = Sim.list_performance_snapshots(version)
  end
end
