defmodule TradingOptionsSim.Repo.Migrations.CreateStrategyVersions do
  use Ecto.Migration

  def change do
    create table(:strategy_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :strategy_id, references(:strategies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :version, :integer, null: false

      add :params, :map, null: false, default: %{}
      add :rules, :map, null: false, default: %{}
      add :usage_conditions, :map, null: false, default: %{}
      add :position_sizing, :map, null: false
      add :direction, :string, null: false, default: "long"

      # See OPTIONS_SIM_ARCHITECTURE_PLAN.md §2 for the full shape:
      # right / expiry_selection / dte_target_days / fixed_expiry /
      # strike_selection / target_delta / multi_leg.
      add :option_leg_config, :map, null: false, default: %{}

      # Three stages, not trading_system's five (no "live" — this app
      # never places a real order; see plan §2's rationale).
      add :lifecycle_stage, :string, null: false, default: "discovery"
      add :quarantine_started_at, :utc_datetime
      add :quarantine_trading_days, :integer, null: false, default: 0
      add :quarantine_last_counted_date, :date
      add :retired_reason, :string

      # Set when a test_portfolio-stage version is promoted OUT to
      # trading_live-or-equivalent for real execution. lifecycle_stage
      # itself never becomes "live" here — same "marker, not a stage
      # advance" pattern trading_system uses for its own promoted_to_live_at.
      add :promoted_to_live_app, :string
      add :promoted_to_live_strategy_id, :binary_id
      add :promoted_to_live_at, :utc_datetime_usec

      # Fork lineage — same shape as trading_system's.
      add :parent_version_id, references(:strategy_versions, type: :binary_id)
      add :generation, :integer, null: false, default: 0

      add :target_pool_id, references(:target_pools, type: :binary_id)

      # Cross-app promotion-in provenance (plan §4). Distinct from
      # parent_version_id/generation — a promoted version starts a wholly
      # new lineage in this app.
      add :source, :string, null: false, default: "native"
      add :source_trading_system_version_id, :binary_id
      add :promoted_at, :utc_datetime
      add :promoted_snapshot, :map

      add :notes, :string
      add :rating, :integer
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:strategy_versions, [:strategy_id])
    create unique_index(:strategy_versions, [:strategy_id, :version])
    create index(:strategy_versions, [:parent_version_id])
    create index(:strategy_versions, [:target_pool_id])
    create index(:strategy_versions, [:lifecycle_stage])

    create constraint(:strategy_versions, :lifecycle_stage_must_be_valid,
             check: "lifecycle_stage in ('discovery', 'quarantine', 'test_portfolio', 'retired')"
           )

    create constraint(:strategy_versions, :direction_must_be_valid,
             check: "direction in ('long', 'short')"
           )

    create constraint(:strategy_versions, :source_must_be_valid,
             check: "source in ('native', 'promoted_from_trading_system')"
           )

    create constraint(:strategy_versions, :rating_must_be_in_range,
             check: "rating is null or (rating >= 1 and rating <= 5)"
           )

    create constraint(:strategy_versions, :generation_must_be_non_negative,
             check: "generation >= 0"
           )
  end
end
