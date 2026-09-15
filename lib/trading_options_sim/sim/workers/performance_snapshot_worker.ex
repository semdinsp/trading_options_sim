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
  """

  use Oban.Worker, queue: :daily_rollups, max_attempts: 3

  require Logger

  alias TradingOptionsSim.Sim

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    counts = Sim.snapshot_all_active_versions()

    Logger.info(
      "PerformanceSnapshotWorker: snapshotted=#{counts.snapshotted} skipped=#{counts.skipped}"
    )

    :ok
  end
end
