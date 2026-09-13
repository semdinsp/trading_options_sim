defmodule TradingOptionsSim.Sim.SimRun do
  @moduledoc """
  One open/close cycle for one option contract — mirrors
  `trading_system`'s `StrategyRun` / `trading_live`'s `LiveOrder`+
  `LiveFill` combined, since there's no real order lifecycle to track
  separately here (a run opens with a simulated fill and closes with
  another). See `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §6.

  Contract identity fields (`symbol`/`expiry`/`right`) are denormalized
  onto the run rather than referencing a separate contracts table — a
  run is for one specific, already-resolved contract, and this app has
  no need to query "every run for symbol X" independent of which
  contract; `sim_runs`' composite index still supports that if it comes
  up. `strike` stays `Decimal` per plan §1's naming/type decision.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(open closed)
  @directions ~w(long short)
  @rights ~w(C P)

  schema "sim_runs" do
    belongs_to :strategy_version, TradingOptionsSim.Sim.StrategyVersion

    field :symbol, :string
    field :expiry, :string
    field :strike, :decimal
    field :right, :string
    field :multiplier, :integer, default: 100

    field :direction, :string, default: "long"
    field :status, :string, default: "open"

    field :entry_at, :utc_datetime_usec
    field :entry_price, :decimal
    field :stop_loss_price, :decimal
    field :take_profit_price, :decimal

    field :exit_at, :utc_datetime_usec
    field :exit_price, :decimal
    field :exit_reason, :string

    field :realized_pnl, :decimal

    field :entry_snapshot, :map, default: %{}
    field :exit_snapshot, :map, default: %{}

    has_many :sim_fills, TradingOptionsSim.Sim.SimFill

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def directions, do: @directions
  def rights, do: @rights

  @doc "Opens a new run — entry fields are set together via `entry_changeset/2` once the entry fill actually completes."
  def changeset(sim_run, attrs) do
    sim_run
    |> cast(attrs, [
      :strategy_version_id,
      :symbol,
      :expiry,
      :strike,
      :right,
      :multiplier,
      :direction
    ])
    |> validate_required([:strategy_version_id, :symbol, :expiry, :strike, :right])
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:right, @rights)
    |> foreign_key_constraint(:strategy_version_id)
  end

  @doc "Records the entry fill — sets entry_at/entry_price plus the risk levels computed from it."
  def entry_changeset(sim_run, attrs) do
    cast(sim_run, attrs, [
      :entry_at,
      :entry_price,
      :stop_loss_price,
      :take_profit_price,
      :entry_snapshot
    ])
  end

  @doc "Closes the run — sets exit_at/exit_price/exit_reason/realized_pnl, flips status to closed."
  def exit_changeset(sim_run, attrs) do
    sim_run
    |> cast(attrs, [
      :exit_at,
      :exit_price,
      :exit_reason,
      :realized_pnl,
      :exit_snapshot
    ])
    |> put_change(:status, "closed")
    |> validate_required([:exit_at, :exit_price, :exit_reason, :realized_pnl])
  end
end
