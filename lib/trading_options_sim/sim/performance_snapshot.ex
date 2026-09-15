defmodule TradingOptionsSim.Sim.PerformanceSnapshot do
  @moduledoc """
  One rollup row for a `StrategyVersion`, computed by
  `TradingOptionsSim.Sim.Workers.PerformanceSnapshotWorker` — a scaled-
  down v1 of `trading_system`'s own `StrategyPerformanceSnapshot`
  (confirmed by reading that schema directly): trade count, win/loss
  split, and gross/net realized P&L plus total estimated commission
  (this app's own addition — `trading_system`'s version has no
  commission field of its own). Sharpe/Sortino/drawdown/expectancy-in-R
  and the rest of that schema's much larger metric set are deliberately
  not ported yet — a real follow-up once this app actually needs to
  compare strategies on more than raw P&L, not an oversight.

  **Append-only, no unique constraint** — same design `trading_system`'s
  own snapshot table uses (confirmed live: no `unique_index`, no
  `on_conflict` upsert there either). Every snapshot is a fresh
  recompute over `period_start`..`period_end` (`period_start` is a
  version's `activated_at`, or `inserted_at` if never activated —
  "since this version's whole track record began", not a single
  calendar day), so a duplicate row from running the worker twice in
  one day costs storage, never correctness: there's no running total
  that compounds across rows. Readers should query "most recent
  snapshot per version" (order by `period_end` desc), not assume one
  row per day.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "performance_snapshots" do
    belongs_to :strategy_version, TradingOptionsSim.Sim.StrategyVersion

    field :lifecycle_stage, :string
    field :period_start, :utc_datetime
    field :period_end, :utc_datetime
    field :computed_at, :utc_datetime

    field :n_trades, :integer, default: 0
    field :n_wins, :integer, default: 0
    field :n_losses, :integer, default: 0
    field :win_rate, :decimal

    field :realized_pnl_gross, :decimal
    field :realized_pnl_net, :decimal
    field :total_commission, :decimal

    timestamps(type: :utc_datetime)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :strategy_version_id,
      :lifecycle_stage,
      :period_start,
      :period_end,
      :computed_at,
      :n_trades,
      :n_wins,
      :n_losses,
      :win_rate,
      :realized_pnl_gross,
      :realized_pnl_net,
      :total_commission
    ])
    |> validate_required([
      :strategy_version_id,
      :lifecycle_stage,
      :period_end,
      :computed_at
    ])
    |> foreign_key_constraint(:strategy_version_id)
  end
end
