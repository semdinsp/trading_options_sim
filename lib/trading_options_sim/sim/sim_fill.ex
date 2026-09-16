defmodule TradingOptionsSim.Sim.SimFill do
  @moduledoc """
  One simulated entry or exit fill for a `SimRun` — see
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §6. `pricing_snapshot` records the
  pricer's own inputs/greeks at fill time (implied vol assumption,
  delta/gamma) for later review — this is a simulator,
  so "what was the fill actually based on" is worth keeping.

  It also records how the fill price itself was chosen, via
  `ContractMonitor`'s own `fill_price_for/4`: `fill_basis` is `"quote"`
  (filled against a real two-sided bid/ask) or `"model_price"` (no
  usable quote -- the Black-Scholes backend, or an IBKR contract with no
  quote tick yet), plus `fill_bid`/`fill_ask`/`fill_spread_fraction` and
  the `fill_slippage` actually given up versus the model mid. Before
  2026-09-16 no slippage was applied at all and every fill was a model
  mid, which flattered any exit that had to cross a wide spread.

  `commission` is an estimate from `TradingCore.Costs.IBKR.option_cost/5`
  (IBKR's published options schedule, Fixed plan — see that module's own
  moduledoc for its unverified-against-real-fills caveats), computed once
  at fill time by `ContractMonitor.submit_entry/2`/`submit_exit/3` and
  stored here rather than recomputed on read — mirrors
  `trading_system`'s own `Order.commission` field (confirmed by reading
  that schema directly). `nil` is a real, distinct state (not yet
  estimated), never coerced to zero.
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
    field :commission, :decimal

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
      :pricing_snapshot,
      :commission
    ])
    |> validate_required([:sim_run_id, :kind, :action, :quantity, :fill_price, :filled_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:action, @actions)
    |> validate_number(:quantity, greater_than: 0)
    |> foreign_key_constraint(:sim_run_id)
  end
end
