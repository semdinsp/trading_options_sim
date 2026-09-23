defmodule TradingOptionsSim.Repo.Migrations.AddExcludedReasonToSimRuns do
  use Ecto.Migration

  # excluded_reason: a run that really happened in the simulator but
  # whose inputs were bad, so it must not count toward any score or
  # lifecycle decision. Distinct from is_churn, which describes trading
  # behaviour, not data quality. First use: "stale_ibkr_data" for the
  # 2026-09-23 runs priced from a frozen IBKR option book (see
  # SimRun.excluded_reasons/0). nil = scored normally.
  def change do
    alter table(:sim_runs) do
      add :excluded_reason, :string
    end
  end
end
