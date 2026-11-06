defmodule TradingOptionsSim.Repo.Migrations.AddTestPortfolioAtToStrategyVersions do
  use Ecto.Migration

  # When the version last entered test_portfolio. Nothing recorded this
  # before: promote_strategy_version(v, "test_portfolio") only changed the
  # stage, and `promoted_at` belongs to the trading_system import (it is
  # nil everywhere). Set by that promote clause from now on.
  #
  # Backfill: the earliest PerformanceSnapshot taken at stage
  # test_portfolio. Snapshots run at 21:00 UTC, so the backfilled value is
  # the end of the promotion day, not the minute of promotion; for
  # versions promoted before snapshots began (2026-09-25) it is the first
  # snapshot, i.e. a "no later than" date.
  def up do
    alter table(:strategy_versions) do
      add :test_portfolio_at, :utc_datetime, null: true
    end

    flush()

    execute("""
    UPDATE strategy_versions v
    SET test_portfolio_at = s.first_at
    FROM (
      SELECT strategy_version_id, date_trunc('second', MIN(computed_at)) AS first_at
      FROM performance_snapshots
      WHERE lifecycle_stage = 'test_portfolio'
      GROUP BY strategy_version_id
    ) s
    WHERE s.strategy_version_id = v.id
    """)
  end

  def down do
    alter table(:strategy_versions) do
      remove :test_portfolio_at
    end
  end
end
