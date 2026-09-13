defmodule TradingOptionsSim.Repo.Migrations.CreateStrategies do
  use Ecto.Migration

  def change do
    create table(:strategies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :notes, :string
      add :asset_class, :string, null: false, default: "options"

      timestamps(type: :utc_datetime)
    end
  end
end
