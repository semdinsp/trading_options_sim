defmodule TradingOptionsSim.Repo.Migrations.AddEntryDelayMinutesToStrategyVersions do
  use Ecto.Migration

  # Operator override for the entry delay, editable on a running strategy
  # (unlike params["entry_delay_minutes"], which is frozen with the
  # version). NULL means no override: fall through to the version param,
  # then the app default. See TradingOptionsSim.EntryDelay.
  def change do
    alter table(:strategy_versions) do
      add :entry_delay_minutes, :integer, null: true
    end

    create constraint(:strategy_versions, :entry_delay_minutes_non_negative,
             check: "entry_delay_minutes IS NULL OR entry_delay_minutes >= 0"
           )
  end
end
