defmodule TradingOptionsSim.Repo.Migrations.AddActivatedAtToStrategyVersions do
  use Ecto.Migration

  # "Activated" was only ever tracked implicitly, via "has an open
  # SimRun" (Sim.list_active_strategy_versions/0, Sim.active_strategy_version_ids/0)
  # — a version that goes flat (its position closes via a rule-triggered
  # exit) but was never explicitly deactivated has NO record of still
  # being "on": SimReactivator (which restarts monitors on app boot)
  # only restores versions with an open run, so a flat-but-active
  # version's monitor is silently lost on any restart and never comes
  # back until an operator manually re-activates it. Confirmed live
  # 2026-09-15: exactly this happened to "Slope Long Calls v2" — its
  # position closed via rule_exit, the app restarted minutes later, and
  # its monitor never restarted even though the operator had never
  # deactivated the strategy.
  #
  # activated_at/deactivated_at (nil-or-timestamp pair, not a plain
  # boolean) mirrors trading_live's own LiveStrategySettings.deactivated_at
  # convention (confirmed by reading that schema directly) — "currently
  # active" is `not is_nil(activated_at) and is_nil(deactivated_at)`, and
  # the timestamps themselves are useful signal on their own (when was
  # this actually turned on/off), not just a derived flag.
  def change do
    alter table(:strategy_versions) do
      add :activated_at, :utc_datetime
      add :deactivated_at, :utc_datetime
    end
  end
end
