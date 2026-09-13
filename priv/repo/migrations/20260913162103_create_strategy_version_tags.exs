defmodule TradingOptionsSim.Repo.Migrations.CreateStrategyVersionTags do
  use Ecto.Migration

  def change do
    create table(:strategy_version_tags, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :strategy_version_id,
          references(:strategy_versions, type: :binary_id, on_delete: :delete_all), null: false

      add :tag_id, references(:tags, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:strategy_version_tags, [:strategy_version_id, :tag_id])
    create index(:strategy_version_tags, [:tag_id])
  end
end
