defmodule TradingOptionsSim.Repo.Migrations.RemoveContractSelectionFromTargetPoolMembers do
  use Ecto.Migration

  # contract_selection was meant as a per-member override of
  # StrategyVersion.option_leg_config (see OPTIONS_SIM_ARCHITECTURE_PLAN.md
  # §3's original text) but SimActivator.activate/1 never actually read it
  # — every member in a pool always gets the version's own
  # option_leg_config unconditionally, matching trading_live's own
  # TargetPoolMember (which has no such field at all: a target pool is
  # just a list of underlyings, and the strategy-level config is what's
  # applied uniformly). Removing the dead, silently-ignored field rather
  # than leaving it to look functional.
  def change do
    alter table(:target_pool_members) do
      remove :contract_selection, :map
    end
  end
end
