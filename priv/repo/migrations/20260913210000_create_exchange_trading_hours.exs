defmodule TradingOptionsSim.Repo.Migrations.CreateExchangeTradingHours do
  use Ecto.Migration

  def change do
    create table(:exchange_trading_hours, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :timezone, :string, null: false
      add :start_time, :time, null: false
      add :end_time, :time, null: false
      add :enabled, :boolean, null: false, default: true
      add :days_of_week, {:array, :integer}, null: false, default: [1, 2, 3, 4, 5]
      add :close_before_minutes, :integer, null: false, default: 11
      add :market, :string, null: false, default: "US_EQUITIES"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:exchange_trading_hours, [:name])
  end
end
