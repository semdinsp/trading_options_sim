defmodule TradingOptionsSim.Sim.Workers.ContractRollWorker do
  @moduledoc """
  Cron-scheduled, weekdays at 13:00 UTC (see `config.exs`): before the
  US open in both EDT (13:30 UTC) and EST (14:30 UTC). Moves flat
  monitors whose contract has reached its expiry window, or whose
  `atm_offset` strike has drifted from today's target (see
  `SimActivator.flat_and_drifted?/2`), onto a fresh contract, and
  deactivates versions whose pinned expiry is spent. See
  `TradingOptionsSim.SimActivator.roll_expiring_contracts/0`.

  Before the open, so a rolled monitor trades its new contract from the
  first minute. EodCloser closes positions in the expiry window at the
  close, so the next morning's run finds them flat and rolls them.
  """

  use Oban.Worker, queue: :daily_rollups, max_attempts: 3

  require Logger

  alias TradingOptionsSim.SimActivator

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    results = SimActivator.roll_expiring_contracts()

    rolled = for {_id, {:rolled, symbols}} <- results, do: length(symbols)
    deactivated = for {id, {:deactivated, _}} <- results, do: id
    waiting = for {id, :waiting} <- results, do: id

    Logger.info(
      "ContractRollWorker: rolled #{Enum.sum(rolled)} monitors on #{length(rolled)} versions, " <>
        "deactivated #{length(deactivated)} #{inspect(deactivated)}, waiting #{length(waiting)}"
    )

    :ok
  end
end
