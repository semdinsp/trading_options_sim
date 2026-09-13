defmodule TradingOptionsSim.Sim.Tag do
  @moduledoc """
  An ad-hoc label a human can apply to any number of `StrategyVersion`s
  or `SimRun`s for filtering/grouping during testing and quarantine
  review — ported from `trading_system.Trading.Tag`/
  `trading_live.LiveTrading.Tag`'s identical pattern (see
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §3a). This app's own local,
  independent tag pool — not shared with either sibling, matching that
  precedent exactly. One shared pool for both associations (not a
  separate tag concept per entity) — a tag like `"needs-review"` can be
  applied to both a strategy version and its own runs.

  `name` is globally unique and upserted by exact string match (no
  case-folding), same scope cut `trading_system`'s
  `get_or_create_tag/1` already made.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tags" do
    field :name, :string
    field :description, :string

    many_to_many :strategy_versions, TradingOptionsSim.Sim.StrategyVersion,
      join_through: TradingOptionsSim.Sim.StrategyVersionTag

    many_to_many :sim_runs, TradingOptionsSim.Sim.SimRun,
      join_through: TradingOptionsSim.Sim.RunTag

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1)
    |> unique_constraint(:name)
  end
end
