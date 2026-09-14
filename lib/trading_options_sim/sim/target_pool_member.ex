defmodule TradingOptionsSim.Sim.TargetPoolMember do
  @moduledoc """
  One equity underlying in a `TargetPool`. Field names (`symbol`,
  `exchange`, `currency`, `ib_conid`) deliberately match `tws_api`'s
  `ContractDetails`/`trading_hub`'s `Order`/`Position` convention rather
  than an "underlying_" prefix — see
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §1's naming note. This row's
  `symbol` is always an equity underlying, never itself an option
  contract — the specific option `contract_key` is resolved per-monitor
  at activation time by combining this member's `symbol` with the
  active `StrategyVersion.option_leg_config` (see plan §3), applied
  identically to every member in the pool. Matches `trading_live`'s own
  `TargetPoolMember` (a pool is just a list of underlyings; the
  strategy-level config is what's applied uniformly) — this schema
  used to also carry a `contract_selection` field meant as a per-member
  override of that config, but `SimActivator.activate/1` never actually
  read it; removed 2026-09-14 rather than leave a dead field that looks
  functional.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "target_pool_members" do
    belongs_to :target_pool, TradingOptionsSim.Sim.TargetPool

    field :symbol, :string
    field :exchange, :string
    field :currency, :string
    field :ib_conid, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [
      :target_pool_id,
      :symbol,
      :exchange,
      :currency,
      :ib_conid
    ])
    |> validate_required([:target_pool_id, :symbol])
    |> foreign_key_constraint(:target_pool_id)
    |> unique_constraint([:target_pool_id, :symbol])
  end
end
