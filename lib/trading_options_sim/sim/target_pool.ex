defmodule TradingOptionsSim.Sim.TargetPool do
  @moduledoc """
  A named, composable subset of underlyings a `StrategyVersion` can be
  scoped to — ported from `trading_system`'s `TargetPool` (see that
  module's own moduledoc for the full motivation: an asset-class-wide
  default is too coarse for "just these 3 underlyings").

  Discovery/quarantine transitions operate on the version, independent of
  which pool it's scoped to — pools have no lifecycle of their own (see
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §3).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @regions ~w(US Asia Europe)

  schema "target_pools" do
    field :name, :string
    field :description, :string
    field :region, :string, default: "US"
    field :inverse, :boolean, default: false
    field :deleted_at, :utc_datetime

    has_many :target_pool_members, TradingOptionsSim.Sim.TargetPoolMember
    has_many :strategy_versions, TradingOptionsSim.Sim.StrategyVersion

    timestamps(type: :utc_datetime)
  end

  @doc "Valid `region` values."
  def regions, do: @regions

  def changeset(target_pool, attrs) do
    target_pool
    |> cast(attrs, [:name, :description, :region, :inverse])
    |> validate_required([:name])
    |> validate_inclusion(:region, @regions)
    |> unique_constraint(:name)
  end
end
