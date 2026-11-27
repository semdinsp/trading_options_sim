defmodule TradingOptionsSim.Repo.Migrations.CreateSimRunStopLadder do
  use Ecto.Migration

  # One row per closed virtual stop (StopLadder rung) per run: what that
  # stop would have done on the same quote stream as the real run. No
  # backfill: runs before the ladder have no rows.
  def change do
    create table(:sim_run_stop_ladder, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :sim_run_id, references(:sim_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :strategy_version_id,
          references(:strategy_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :ladder_version, :integer, null: false
      add :rung_kind, :string, null: false
      add :rung_value, :float
      add :with_tp, :boolean, null: false
      add :exit_price, :decimal, null: false
      add :exit_reason, :string, null: false
      add :exit_at, :utc_datetime_usec, null: false
      add :underlying_at_exit, :float
      add :pnl_net, :decimal, null: false
      add :r_net, :float
      add :mae_pct, :float, null: false
      add :mfe_pct, :float, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:sim_run_stop_ladder, [:strategy_version_id])
    create index(:sim_run_stop_ladder, [:sim_run_id])
  end
end
