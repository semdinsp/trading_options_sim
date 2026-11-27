defmodule TradingOptionsSim.Sim.SimRunStopLadder do
  @moduledoc """
  One closed virtual stop on one run (see `TradingOptionsSim.StopLadder`):
  `rung_kind` "premium" (value = stop %, nil = no stop), "underlying"
  (value = multiple of the 20-minute ATR) or "time" (value = minutes),
  each `with_tp` or without the version's take-profit. `exit_reason` is
  "stop", "tp", "rule" or "eod"; `r_net` is net P&L over premium at
  risk, as `Sim`'s R. Written by `ContractMonitor`, read by
  `Sim.stop_sizing/2`.
  """

  use Ecto.Schema

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sim_run_stop_ladder" do
    belongs_to :sim_run, TradingOptionsSim.Sim.SimRun
    belongs_to :strategy_version, TradingOptionsSim.Sim.StrategyVersion

    field :ladder_version, :integer
    field :rung_kind, :string
    field :rung_value, :float
    field :with_tp, :boolean
    field :exit_price, :decimal
    field :exit_reason, :string
    field :exit_at, :utc_datetime_usec
    field :underlying_at_exit, :float
    field :pnl_net, :decimal
    field :r_net, :float
    field :mae_pct, :float
    field :mfe_pct, :float

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
