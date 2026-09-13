defmodule TradingOptionsSim.Repo.Migrations.CreateSimFills do
  use Ecto.Migration

  def change do
    create table(:sim_fills, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :sim_run_id, references(:sim_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :action, :string, null: false
      add :quantity, :integer, null: false
      add :fill_price, :decimal, null: false
      add :filled_at, :utc_datetime_usec, null: false

      # Snapshot of the pricer's own inputs/greeks at fill time — useful
      # for reviewing exactly what the simulated fill was based on
      # (implied vol assumption, slippage applied, delta/gamma at fill).
      add :pricing_snapshot, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sim_fills, [:sim_run_id])

    create constraint(:sim_fills, :kind_must_be_valid, check: "kind in ('entry', 'exit')")
    create constraint(:sim_fills, :action_must_be_valid, check: "action in ('buy', 'sell')")
    create constraint(:sim_fills, :quantity_must_be_positive, check: "quantity > 0")
  end
end
