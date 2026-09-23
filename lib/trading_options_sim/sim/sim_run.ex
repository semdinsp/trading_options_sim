defmodule TradingOptionsSim.Sim.SimRun do
  @moduledoc """
  One open/close cycle for one option contract — mirrors
  `trading_system`'s `StrategyRun` / `trading_live`'s `LiveOrder`+
  `LiveFill` combined, since there's no real order lifecycle to track
  separately here (a run opens with a simulated fill and closes with
  another). See `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §6.

  Contract identity fields (`symbol`/`expiry`/`right`) are denormalized
  onto the run rather than referencing a separate contracts table — a
  run is for one specific, already-resolved contract, and this app has
  no need to query "every run for symbol X" independent of which
  contract; `sim_runs`' composite index still supports that if it comes
  up. `strike` stays `Decimal` per plan §1's naming/type decision.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(open closed)
  @directions ~w(long short)
  @rights ~w(C P)

  schema "sim_runs" do
    belongs_to :strategy_version, TradingOptionsSim.Sim.StrategyVersion

    field :symbol, :string
    field :expiry, :string
    field :strike, :decimal
    field :right, :string
    field :multiplier, :integer, default: 100

    field :direction, :string, default: "long"
    field :status, :string, default: "open"

    field :entry_at, :utc_datetime_usec
    field :entry_price, :decimal
    field :stop_loss_price, :decimal
    field :take_profit_price, :decimal
    field :risk_at_entry, :decimal

    field :exit_at, :utc_datetime_usec
    field :exit_price, :decimal
    field :exit_reason, :string

    field :realized_pnl, :decimal
    field :realized_pnl_net, :decimal

    field :entry_snapshot, :map, default: %{}
    field :exit_snapshot, :map, default: %{}

    field :context, :map, default: %{}

    field :is_churn, :boolean, default: false

    # Data-quality exclusion, orthogonal to is_churn: see
    # excluded_reasons/0 and exclusion_changeset/2.
    field :excluded_reason, :string

    has_many :sim_fills, TradingOptionsSim.Sim.SimFill

    many_to_many :tags, TradingOptionsSim.Sim.Tag,
      join_through: TradingOptionsSim.Sim.RunTag,
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def directions, do: @directions
  def rights, do: @rights

  @doc "Opens a new run — entry fields are set together via `entry_changeset/2` once the entry fill actually completes."
  def changeset(sim_run, attrs) do
    sim_run
    |> cast(attrs, [
      :strategy_version_id,
      :symbol,
      :expiry,
      :strike,
      :right,
      :multiplier,
      :direction
    ])
    |> validate_required([:strategy_version_id, :symbol, :expiry, :strike, :right])
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:right, @rights)
    |> foreign_key_constraint(:strategy_version_id)
  end

  @doc """
  Records the entry fill — sets entry_at/entry_price plus the risk
  levels computed from it. `context` is a free-form, deliberately
  exploratory map (regime label, days-to-expiry-at-entry, implied
  volatility assumption are the first candidates, not a closed set —
  see the `add_context_to_sim_runs` migration's own comment) stamped
  once here, at entry, and never updated afterward — mirrors
  `trading_live`'s own regime columns being stamped once on the opening
  fill only (confirmed by reading `LiveFill`'s schema directly).

  `risk_at_entry` is the expectancy_r/lcb95/ucb95 R-multiple denominator
  — see `Sim.compute_risk_at_entry/1`'s own doc (and its TODO) for what
  it actually measures today.
  """
  def entry_changeset(sim_run, attrs) do
    cast(sim_run, attrs, [
      :entry_at,
      :entry_price,
      :stop_loss_price,
      :take_profit_price,
      :risk_at_entry,
      :entry_snapshot,
      :context
    ])
  end

  @doc """
  Flags this run as churn — a flatten-and-reopen loop, not a genuine
  independent trade. See `Sim.maybe_mark_prior_run_as_churn/2`'s own doc
  for the detection thresholds. Applied retroactively to an
  already-closed run once a qualifying reopen is observed, mirroring
  `trading_system`'s own `StrategyRun.churn_changeset/1` (confirmed by
  reading that schema directly).
  """
  def churn_changeset(sim_run) do
    change(sim_run, is_churn: true)
  end

  @excluded_reasons ~w(stale_ibkr_data)

  @doc """
  Why a run can be excluded from scoring. A run excluded here really
  happened in the simulator, but its inputs were bad, so it must not
  count toward any metric, gate or lifecycle decision.

    * `"stale_ibkr_data"` -- priced from an IBKR option tick/quote that
      had stopped updating. 2026-09-23: trading_hub lost its option
      subscriptions at ~09:57 ET and monitors kept trading against the
      cached book until the close (fixed going forward by
      ContractMonitor's staleness gate).
  """
  @spec excluded_reasons() :: [String.t()]
  def excluded_reasons, do: @excluded_reasons

  @doc "Marks this run as excluded from scoring for `reason`."
  def exclusion_changeset(sim_run, reason) do
    sim_run
    |> change(excluded_reason: reason)
    |> validate_inclusion(:excluded_reason, @excluded_reasons)
  end

  @doc """
  Closes the run — sets exit_at/exit_price/exit_reason/realized_pnl,
  flips status to closed. `realized_pnl_net` (realized_pnl minus the
  entry+exit fills' summed commission — see `Sim.total_run_commission/1`)
  is optional here and left `nil`, never coerced to zero, whenever either
  leg's commission hasn't been estimated — mirrors `trading_system`'s own
  `realized_pnl_net` (confirmed by reading its `close_run/3`).
  """
  def exit_changeset(sim_run, attrs) do
    sim_run
    |> cast(attrs, [
      :exit_at,
      :exit_price,
      :exit_reason,
      :realized_pnl,
      :realized_pnl_net,
      :exit_snapshot
    ])
    |> put_change(:status, "closed")
    |> validate_required([:exit_at, :exit_price, :exit_reason, :realized_pnl])
  end

  @doc """
  Closes a run that never received an entry fill — its own monitor was
  deactivated (or otherwise stopped) while still flat, watching for an
  entry that never triggered. Unlike `exit_changeset/2`, there is no
  `entry_price`/`exit_price`/`realized_pnl` to record (nothing was ever
  filled): only `exit_at`/`exit_reason` are required, and `entry_price`/
  `exit_price`/`realized_pnl` stay `nil` — a real, distinct run outcome
  ("activated, never triggered, then stopped"), not a trade with zero
  P&L. See `Sim.close_run_without_entry/2`'s own doc for the caller.
  """
  def close_without_entry_changeset(sim_run, attrs) do
    sim_run
    |> cast(attrs, [:exit_at, :exit_reason])
    |> put_change(:status, "closed")
    |> validate_required([:exit_at, :exit_reason])
  end
end
