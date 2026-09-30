defmodule TradingOptionsSim.Sim.Workers.PerformanceSnapshotWorker do
  @moduledoc """
  Cron-scheduled, once daily (21:00 UTC — see `config.exs`'s
  `Oban.Plugins.Cron` entry; 1 hour after the US options market's 4pm ET
  close during EDT). Calls `Sim.snapshot_all_active_versions/0`, a pure
  delegator that writes one `PerformanceSnapshot` row per
  discovery/quarantine/test_portfolio-stage version with at least one
  closed run in its window — see that function's own doc. Ported from
  `TradingSystem.Trading.Workers.PerformanceSnapshotWorker`'s identical
  "delegate + log counts" shape, scoped down to this app's much smaller
  v1 metric set (see `PerformanceSnapshot`'s own moduledoc for what's
  deferred).

  Its own dedicated slot, not stacked with `QuarantineEligibilityWorker`'s
  07:00 UTC morning slot — that worker's own timing exists specifically
  to run *after* the prior trading day has fully closed and processed;
  this worker's job is the opposite: run shortly after *today's* close,
  same day, not the next morning. `window` is a version's own
  `activated_at`-to-now span (see `Sim.snapshot_version/2`), not a
  single calendar day, so there's no risk of this racing yesterday's
  data the way a `Date.utc_today()` call at a pre-market hour would.

  ## Missed versions cancel the job

  A version that closed a run in the last 24 hours but still got no
  snapshot (`counts.missed > 0`) means its window is wrong — see
  `Sim.snapshot_all_active_versions/0`. The job then returns
  `{:cancel, reason}`, so the System Performance page's Cron / Oban
  Health panel shows it as CANCELLED instead of a green COMPLETED.
  Deliberately not `{:error, _}`: a retry would re-insert every snapshot
  this run already wrote (the table is append-only) and could not fix
  the window anyway.
  """

  use Oban.Worker, queue: :daily_rollups, max_attempts: 3

  require Logger

  alias TradingOptionsSim.Sim

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    counts = Sim.snapshot_all_active_versions()

    Logger.info(
      "PerformanceSnapshotWorker: snapshotted=#{counts.snapshotted} skipped=#{counts.skipped} missed=#{counts.missed}"
    )

    if counts.missed > 0 do
      reason =
        "#{counts.missed} version(s) closed runs in the last 24h but got no snapshot — " <>
          "check activated_at (snapshot windows start there)"

      Logger.error("PerformanceSnapshotWorker: #{reason}")
      {:cancel, reason}
    else
      :ok
    end
  end
end
