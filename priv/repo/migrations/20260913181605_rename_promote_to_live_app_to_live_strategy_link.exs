defmodule TradingOptionsSim.Repo.Migrations.RenamePromoteToLiveAppToLiveStrategyLink do
  use Ecto.Migration

  def change do
    rename table(:strategy_versions), :promoted_to_live_app, to: :live_strategy_app
    rename table(:strategy_versions), :promoted_to_live_strategy_id, to: :live_strategy_id
    rename table(:strategy_versions), :promoted_to_live_at, to: :live_linked_at

    alter table(:strategy_versions) do
      add :live_strategy_active, :boolean, null: false, default: false
      add :live_unlinked_at, :utc_datetime
    end
  end
end
