defmodule TradingOptionsSim.Repo.Migrations.AddRiskAndChurnToSimRuns do
  use Ecto.Migration

  # risk_at_entry: the R-multiple denominator for expectancy_r/lcb95/ucb95
  # (Sim.full_universe_version_metrics/1) — entry_price * multiplier *
  # quantity, the premium at risk on a long option position (the
  # standard convention for a defined-risk position with no stop). No
  # strategy in this app sets a stop-loss yet (SimRun.stop_loss_price
  # has no writer anywhere in the codebase, confirmed 2026-09-15) — see
  # Sim.compute_risk_at_entry/1's own TODO for switching stopped-out
  # trades to a stop-distance-based risk_at_entry once automatic
  # stop-loss exercise exists.
  #
  # is_churn: mirrors trading_system's own StrategyRun.is_churn — a
  # retroactive flag on the PRIOR run when the same
  # {strategy_version_id, symbol} closes with a short hold time and
  # reopens shortly after (see Sim.maybe_mark_prior_run_as_churn/2).
  # Excluded from expectancy_r/lcb95/ucb95/realized_pnl aggregation.
  def change do
    alter table(:sim_runs) do
      add :risk_at_entry, :decimal
      add :is_churn, :boolean, null: false, default: false
    end

    create index(:sim_runs, [:strategy_version_id, :symbol, :exit_at])
  end
end
