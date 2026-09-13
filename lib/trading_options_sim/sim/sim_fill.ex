defmodule TradingOptionsSim.Sim.SimFill do
  @moduledoc """
  One simulated entry or exit fill for a `SimRun` — see
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §6. `pricing_snapshot` records the
  pricer's own inputs/greeks at fill time (implied vol assumption,
  slippage applied, delta/gamma) for later review — this is a simulator,
  so "what was the fill actually based on" is worth keeping.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(entry exit)
  @actions ~w(buy sell)

  schema "sim_fills" do
    belongs_to :sim_run, TradingOptionsSim.Sim.SimRun

    field :kind, :string
    field :action, :string
    field :quantity, :integer
    field :fill_price, :decimal
    field :filled_at, :utc_datetime_usec
    field :pricing_snapshot, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def actions, do: @actions

  def changeset(sim_fill, attrs) do
    sim_fill
    |> cast(attrs, [
      :sim_run_id,
      :kind,
      :action,
      :quantity,
      :fill_price,
      :filled_at,
      :pricing_snapshot
    ])
    |> validate_required([:sim_run_id, :kind, :action, :quantity, :fill_price, :filled_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:action, @actions)
    |> validate_number(:quantity, greater_than: 0)
    |> foreign_key_constraint(:sim_run_id)
  end
end
