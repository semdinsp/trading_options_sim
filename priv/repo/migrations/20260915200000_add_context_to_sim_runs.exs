defmodule TradingOptionsSim.Repo.Migrations.AddContextToSimRuns do
  use Ecto.Migration

  # A JSON map rather than dedicated columns per field — deliberately
  # exploratory (regime label, days-to-expiry-at-entry, implied
  # volatility assumption are the first candidates, not a closed set)
  # while it's still unclear which of these end up load-bearing for a
  # per-regime/per-DTE-bucket performance rollup. Once a specific key
  # proves stable and query-heavy enough to want a real SQL GROUP BY
  # (rather than the Enum.group_by/2-after-fetch approach trading_live's
  # own regime rollup already uses at similar data volumes — confirmed
  # by reading TradingLive.PerformanceMetrics.expectancy_by_regime/1
  # directly), promote that one key to its own indexed column alongside
  # this map, not instead of it.
  def change do
    alter table(:sim_runs) do
      add :context, :map, default: %{}
    end
  end
end
