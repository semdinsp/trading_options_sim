defmodule TradingOptionsSim.Repo.Migrations.CreateExchangeSessions do
  use Ecto.Migration

  def change do
    create table(:exchange_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :exchange, :string, null: false

      add :exchange_trading_hours_id,
          references(:exchange_trading_hours, type: :binary_id, on_delete: :restrict),
          null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:exchange_sessions, [:exchange])
    create index(:exchange_sessions, [:exchange_trading_hours_id])
  end
end
