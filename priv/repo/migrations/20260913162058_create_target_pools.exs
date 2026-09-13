defmodule TradingOptionsSim.Repo.Migrations.CreateTargetPools do
  use Ecto.Migration

  def change do
    create table(:target_pools, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :region, :string, null: false, default: "US"
      add :inverse, :boolean, null: false, default: false
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:target_pools, [:name])
  end
end
