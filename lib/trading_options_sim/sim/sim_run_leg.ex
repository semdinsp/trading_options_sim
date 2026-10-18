defmodule TradingOptionsSim.Sim.SimRunLeg do
  @moduledoc """
  One contract of a multi-leg combo `SimRun` (a credit vertical or an
  iron condor). A combo is one run, so it counts as one trade in every
  score; its legs live here. `side` is per leg ("short" = sold, "long" =
  bought) and independent of the run's own `direction`.

  `entry_price`/`exit_price` are this leg's own fill prices, per share.
  The run's `entry_price`/`exit_price` hold the NET price of the whole
  combo (the credit received, for a credit structure), which is what its
  stops, targets and P&L are computed from. See
  `TradingOptionsSim.Combo`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @rights ~w(C P)
  @sides ~w(long short)

  schema "sim_run_legs" do
    belongs_to :sim_run, TradingOptionsSim.Sim.SimRun

    field :leg_index, :integer
    field :expiry, :string
    field :strike, :decimal
    field :right, :string
    field :side, :string
    field :ratio, :integer, default: 1
    field :entry_price, :decimal
    field :exit_price, :decimal

    timestamps(type: :utc_datetime_usec)
  end

  def sides, do: @sides

  def changeset(leg, attrs) do
    leg
    |> cast(attrs, [
      :sim_run_id,
      :leg_index,
      :expiry,
      :strike,
      :right,
      :side,
      :ratio,
      :entry_price,
      :exit_price
    ])
    |> validate_required([:sim_run_id, :leg_index, :expiry, :strike, :right, :side])
    |> validate_inclusion(:right, @rights)
    |> validate_inclusion(:side, @sides)
    |> validate_number(:ratio, greater_than: 0)
    |> validate_number(:leg_index, greater_than_or_equal_to: 0)
    |> unique_constraint([:sim_run_id, :leg_index])
    |> foreign_key_constraint(:sim_run_id)
  end
end
