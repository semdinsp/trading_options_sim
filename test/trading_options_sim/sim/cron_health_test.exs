defmodule TradingOptionsSim.Sim.CronHealthTest do
  use TradingOptionsSim.DataCase, async: true

  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.Workers.QuarantineEligibilityWorker

  describe "cron_worker_health/0" do
    test "matches a real completed job against its worker, not just nil-for-everyone" do
      # Regression coverage for the exact bug trading_system hit: comparing
      # oban_jobs.worker (stored WITHOUT the "Elixir." prefix —
      # Oban.Worker.to_string/1 strips it) against Kernel.to_string(worker),
      # which keeps the prefix, silently fails every comparison. Oban runs
      # in testing: :manual (config/test.exs) — insert/1 doesn't actually
      # process the job, so simulate a real completed row explicitly, the
      # way the real Oban engine would after a successful run, since that
      # DB row (not an in-memory perform/1 call) is exactly what
      # cron_worker_health/0 reads.
      {:ok, job} = %{} |> QuarantineEligibilityWorker.new() |> Oban.insert()

      {:ok, _job} =
        job
        |> Ecto.Changeset.change(state: "completed", completed_at: DateTime.utc_now())
        |> TradingOptionsSim.Repo.update()

      health = Sim.cron_worker_health()
      row = Enum.find(health, &(&1.worker == QuarantineEligibilityWorker))

      refute is_nil(row.last_job)
      refute is_nil(row.last_success)
      assert row.last_success.state == "completed"
    end

    test "a worker with no jobs at all reports nil for last_job/last_success/second_last_success" do
      health = Sim.cron_worker_health()
      row = Enum.find(health, &(&1.worker == QuarantineEligibilityWorker))

      assert is_nil(row.last_job)
      assert is_nil(row.last_success)
      assert is_nil(row.second_last_success)
    end

    test "second_last_success is the completed job just before last_success, not the same row twice" do
      older_completed_at = DateTime.add(DateTime.utc_now(), -2, :day)
      newer_completed_at = DateTime.utc_now()

      {:ok, older_job} = %{} |> QuarantineEligibilityWorker.new() |> Oban.insert()

      {:ok, _older_job} =
        older_job
        |> Ecto.Changeset.change(state: "completed", completed_at: older_completed_at)
        |> TradingOptionsSim.Repo.update()

      {:ok, newer_job} = %{} |> QuarantineEligibilityWorker.new() |> Oban.insert()

      {:ok, _newer_job} =
        newer_job
        |> Ecto.Changeset.change(state: "completed", completed_at: newer_completed_at)
        |> TradingOptionsSim.Repo.update()

      health = Sim.cron_worker_health()
      row = Enum.find(health, &(&1.worker == QuarantineEligibilityWorker))

      assert row.last_success.id == newer_job.id
      assert row.second_last_success.id == older_job.id
    end
  end

  describe "oban_pending_job_count/0" do
    test "counts jobs in available/scheduled/retryable/executing states" do
      {:ok, _available} = %{} |> QuarantineEligibilityWorker.new() |> Oban.insert()

      {:ok, completed} = %{} |> QuarantineEligibilityWorker.new() |> Oban.insert()

      {:ok, _completed} =
        completed
        |> Ecto.Changeset.change(state: "completed", completed_at: DateTime.utc_now())
        |> TradingOptionsSim.Repo.update()

      assert Sim.oban_pending_job_count() == 1
    end
  end
end
