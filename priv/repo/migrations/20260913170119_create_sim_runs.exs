defmodule TradingOptionsSim.Repo.Migrations.CreateSimRuns do
  use Ecto.Migration

  def change do
    create table(:sim_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :strategy_version_id,
          references(:strategy_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      # Denormalized contract identity (OPTIONS_SIM_ARCHITECTURE_PLAN.md
      # §1) — a run is for one specific option contract, not just an
      # underlying symbol. symbol/expiry/right match tws_api's own field
      # names/wire-format expiry string; strike stays Decimal (this
      # app's one deliberate exception — see plan §1).
      add :symbol, :string, null: false
      add :expiry, :string, null: false
      add :strike, :decimal, null: false
      add :right, :string, null: false
      add :multiplier, :integer, null: false, default: 100

      add :direction, :string, null: false, default: "long"

      add :status, :string, null: false, default: "open"

      add :entry_at, :utc_datetime_usec
      add :entry_price, :decimal
      add :stop_loss_price, :decimal
      add :take_profit_price, :decimal

      add :exit_at, :utc_datetime_usec
      add :exit_price, :decimal
      add :exit_reason, :string

      add :realized_pnl, :decimal

      add :entry_snapshot, :map, null: false, default: %{}
      add :exit_snapshot, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:sim_runs, [:strategy_version_id])
    create index(:sim_runs, [:status])
    create index(:sim_runs, [:symbol, :expiry, :strike, :right])

    create constraint(:sim_runs, :status_must_be_valid, check: "status in ('open', 'closed')")

    create constraint(:sim_runs, :direction_must_be_valid,
             check: "direction in ('long', 'short')"
           )

    create constraint(:sim_runs, :right_must_be_valid, check: "\"right\" in ('C', 'P')")
  end
end
