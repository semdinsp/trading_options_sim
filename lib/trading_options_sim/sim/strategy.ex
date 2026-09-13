defmodule TradingOptionsSim.Sim.Strategy do
  @moduledoc """
  A named options strategy — the parent of one or more immutable
  `StrategyVersion`s. See `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §2.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "strategies" do
    field :name, :string
    field :notes, :string
    field :asset_class, :string, default: "options"

    has_many :strategy_versions, TradingOptionsSim.Sim.StrategyVersion

    timestamps(type: :utc_datetime)
  end

  def changeset(strategy, attrs) do
    strategy
    |> cast(attrs, [:name, :notes, :asset_class])
    |> validate_required([:name])
  end

  @doc "Same deliberate-exception shape as `trading_system`'s `set_strategy_notes/2` — notes are revisable after creation."
  def notes_changeset(strategy, attrs) do
    cast(strategy, attrs, [:notes])
  end
end
