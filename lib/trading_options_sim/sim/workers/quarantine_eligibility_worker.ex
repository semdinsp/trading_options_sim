defmodule TradingOptionsSim.Sim.Workers.QuarantineEligibilityWorker do
  @moduledoc """
  Cron-scheduled, once daily (07:00 UTC — see `config.exs`'s
  `Oban.Plugins.Cron` entry). Runs
  `Sim.run_quarantine_eligibility_check/1`'s three jobs, in order —
  day-count update for already-quarantined versions, then auto-promotion
  of eligible `discovery`-stage versions, then the automatic
  `quarantine -> retired` gate for versions failing on tenure + loss
  ratio. Ported from `TradingSystem.Trading.Workers.QuarantineEligibilityWorker`,
  scoped down to this app's much simpler v1 gates — then
  `TradingOptionsSim.LifecycleReview.run/1` (deactivate losers, fork
  regime-profitable ones with a regime gate). See
  `Sim.run_quarantine_eligibility_check/1`'s own moduledoc for why job
  1-then-3's ordering is load-bearing.
  """

  use Oban.Worker, queue: :daily_rollups, max_attempts: 3

  alias TradingOptionsSim.Sim

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    :ok = Sim.run_quarantine_eligibility_check()
    # After job 3, so a quarantine loser with no profitable regime has
    # already been retired and only regime rescues remain for it.
    _ = TradingOptionsSim.LifecycleReview.run()
    :ok
  end
end
