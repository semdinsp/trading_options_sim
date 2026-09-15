defmodule TradingOptionsSim.Repo.Migrations.AddTradingHoursPolicyToStrategyVersions do
  use Ecto.Migration

  # Ported from trading_live's own LiveStrategySettings.after_hours_policy
  # + overnight_hold (confirmed by reading that schema directly) —
  # trading_hours_policy gates order transmission at evaluation time
  # (ContractMonitor.session_open?/1), not activation; overnight_hold
  # suppresses EodCloser's automatic force-close, manual-only toggle,
  # no auto re-enable. Both live directly on strategy_versions rather
  # than a separate 1:1 settings table (trading_live's own split exists
  # because LiveStrategy is a frozen promotion snapshot with a separate
  # mutable-settings row bolted on; StrategyVersion here has no such
  # split to preserve).
  def change do
    alter table(:strategy_versions) do
      add :trading_hours_policy, :string, null: false, default: "regular_hours_only"
      add :overnight_hold, :boolean, null: false, default: false
    end
  end
end
