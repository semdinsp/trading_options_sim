defmodule TradingOptionsSim.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :label, :string, null: false
      add :token_hash, :binary, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_tokens, [:token_hash])
  end
end
