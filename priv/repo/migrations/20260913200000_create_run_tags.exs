defmodule TradingOptionsSim.Repo.Migrations.CreateRunTags do
  use Ecto.Migration

  def change do
    create table(:run_tags, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :sim_run_id, references(:sim_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :tag_id, references(:tags, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:run_tags, [:sim_run_id, :tag_id])
    create index(:run_tags, [:tag_id])
  end
end
