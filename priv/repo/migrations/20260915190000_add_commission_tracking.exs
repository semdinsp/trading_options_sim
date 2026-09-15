defmodule TradingOptionsSim.Repo.Migrations.AddCommissionTracking do
  use Ecto.Migration

  # Mirrors trading_system's own commission/realized_pnl_net split
  # (confirmed by reading TradingSystem.Trading.Order/StrategyRun
  # directly): commission is computed once per fill and stored on the
  # fill itself (an order can fill in multiple executions there;
  # sim_fills has exactly one row per entry/exit here, so "per order" and
  # "per fill" coincide for this app), then summed across a run's two
  # fills into realized_pnl_net at exit time. realized_pnl (existing
  # column) is left untouched as the gross figure — commission-adjusted
  # net is additive, not a replacement, matching every other REST/MCP
  # consumer of realized_pnl already wired up.
  def change do
    alter table(:sim_fills) do
      add :commission, :decimal
    end

    alter table(:sim_runs) do
      add :realized_pnl_net, :decimal
    end
  end
end
