defmodule TradingOptionsSim.Repo.Migrations.CreateTargetPoolMembers do
  use Ecto.Migration

  def change do
    create table(:target_pool_members, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :target_pool_id, references(:target_pools, type: :binary_id, on_delete: :delete_all),
        null: false

      # The equity underlying's own identity — plain field names, matching
      # tws_api/trading_hub's ContractDetails.symbol convention (see
      # OPTIONS_SIM_ARCHITECTURE_PLAN.md §1) rather than an "underlying_"
      # prefix. This row's symbol/exchange/currency are always an equity
      # underlying, never an option contract itself.
      add :symbol, :string, null: false
      add :exchange, :string
      add :currency, :string
      add :ib_conid, :integer

      # Same shape as StrategyVersion.option_leg_config's expiry/strike
      # selection fields, or null to inherit the version's own config
      # unchanged (the expected common case — see plan §3).
      add :contract_selection, :map

      timestamps(type: :utc_datetime)
    end

    create index(:target_pool_members, [:target_pool_id])
    create unique_index(:target_pool_members, [:target_pool_id, :symbol])
  end
end
