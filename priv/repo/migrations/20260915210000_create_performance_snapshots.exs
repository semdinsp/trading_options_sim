defmodule TradingOptionsSim.Repo.Migrations.CreatePerformanceSnapshots do
  use Ecto.Migration

  # No unique index on {strategy_version_id, period_end} — append-only,
  # same design trading_system's own StrategyPerformanceSnapshot uses
  # (confirmed by reading that schema/migration directly): each worker
  # run is a fresh recompute over the version's whole history to date,
  # so a duplicate row from running twice in one day costs storage, not
  # correctness (no running-total math compounds across rows). A plain
  # lookup index is enough for "most recent snapshot per version."
  def change do
    create table(:performance_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :strategy_version_id,
          references(:strategy_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :lifecycle_stage, :string, null: false
      add :period_start, :utc_datetime
      add :period_end, :utc_datetime, null: false
      add :computed_at, :utc_datetime, null: false

      add :n_trades, :integer, null: false, default: 0
      add :n_wins, :integer, null: false, default: 0
      add :n_losses, :integer, null: false, default: 0
      add :win_rate, :decimal
      add :realized_pnl_gross, :decimal
      add :realized_pnl_net, :decimal
      add :total_commission, :decimal

      timestamps(type: :utc_datetime)
    end

    create index(:performance_snapshots, [:strategy_version_id, :period_end])
  end
end
