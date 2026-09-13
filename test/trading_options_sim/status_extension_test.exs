defmodule TradingOptionsSim.StatusExtensionTest do
  use TradingOptionsSim.DataCase

  alias TradingOptionsSim.StatusExtension

  test "extra_metrics/0 returns both checks with the right shape" do
    metrics = StatusExtension.extra_metrics()

    assert is_boolean(metrics.hub_connected)
    assert %{up?: up?} = metrics.db_pool
    assert is_boolean(up?)
  end

  test "hub_connected?/0 is false when TradingOptionsSim.HubMonitor isn't registered" do
    refute Process.whereis(TradingOptionsSim.HubMonitor)
    refute StatusExtension.hub_connected?()
  end

  test "db_pool_stats/0 reports pool config alongside up?" do
    stats = StatusExtension.db_pool_stats()

    assert is_integer(stats.pool_size)
    assert is_boolean(stats.up?)
  end

  test "db_up?/0 is true against the real test-sandbox connection" do
    assert StatusExtension.db_up?()
  end

  test "extra_metrics/0 completes well inside AppStatus.Extension's 2000ms budget" do
    {time_us, _metrics} = :timer.tc(&StatusExtension.extra_metrics/0)
    assert time_us < 1_000_000
  end
end
