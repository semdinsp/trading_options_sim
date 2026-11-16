defmodule TradingOptionsSim.Sim.Workers.ContractRollWorkerTest do
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.Sim.Workers.ContractRollWorker

  test "perform/1 succeeds with nothing to roll" do
    assert :ok = ContractRollWorker.perform(%Oban.Job{})
  end

  test "is scheduled in the cron table and reported by cron_worker_health/0" do
    assert ContractRollWorker in Enum.map(TradingOptionsSim.Sim.cron_worker_health(), & &1.worker)

    crontab =
      :trading_options_sim
      |> Application.fetch_env!(Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
        _ -> nil
      end)

    assert {"0 13 * * 1-5", ContractRollWorker} in crontab
  end
end
