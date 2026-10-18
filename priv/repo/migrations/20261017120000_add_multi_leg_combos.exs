defmodule TradingOptionsSim.Repo.Migrations.AddMultiLegCombos do
  use Ecto.Migration

  # Multi-leg combos (credit verticals, iron condors), stage 1 of 3.
  #
  # One combo trade is ONE sim_run (so every score, gate and lifecycle
  # count treats it as one trade) whose legs live in sim_run_legs.
  # sim_runs.structure is nil for a single-leg run and names the
  # structure for a combo; when it is set, sim_run_legs is the source of
  # truth for the contracts. The run's own strike/right stay NOT NULL
  # and hold the primary short leg, so every existing view that renders
  # them keeps working.
  #
  # sim_fills.leg_index says which leg a fill belongs to (nil on a
  # single-leg run), so a combo's per-leg fills and commissions stay
  # auditable one by one.
  def change do
    alter table(:sim_runs) do
      add :structure, :string
    end

    create table(:sim_run_legs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :sim_run_id, references(:sim_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :leg_index, :integer, null: false
      add :expiry, :string, null: false
      add :strike, :decimal, null: false
      add :right, :string, null: false
      # "long" (bought) or "short" (sold) -- per leg, independent of the
      # run's own direction.
      add :side, :string, null: false
      add :ratio, :integer, null: false, default: 1
      add :entry_price, :decimal
      add :exit_price, :decimal

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sim_run_legs, [:sim_run_id, :leg_index])

    create constraint(:sim_run_legs, :leg_right_must_be_valid, check: "\"right\" in ('C', 'P')")
    create constraint(:sim_run_legs, :leg_side_must_be_valid, check: "side in ('long', 'short')")
    create constraint(:sim_run_legs, :leg_ratio_must_be_positive, check: "ratio > 0")

    alter table(:sim_fills) do
      add :leg_index, :integer
    end
  end
end
