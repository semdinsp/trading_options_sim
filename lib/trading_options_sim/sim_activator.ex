defmodule TradingOptionsSim.SimActivator do
  @moduledoc """
  Starts `ContractMonitor`s for a `StrategyVersion`'s target pool
  members, mirroring `TradingLive.StrategyActivator`'s
  `start_for_member/2` shape. See `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §6.

  ## v1 contract resolution

  `option_leg_config`'s `"strike_selection"`/`"expiry_selection"` fields
  (`fixed_delta`/`dte_target`/etc — see plan §2) describe how a real
  options-chain-aware resolver would eventually pick a contract, but no
  such resolver exists yet (needs `trading_hub`'s live options chain
  data, not yet frame-verified — see plan §5a's update note). v1 only
  supports `"fixed_strike"`/`"fixed"` selection, requiring
  `option_leg_config` to carry the exact `"strike"`/`"expiry"` to trade
  — `activate/1` returns `{:error, :unsupported_leg_config}` for
  anything else rather than guessing a contract. This is a real,
  deliberate gap, not an oversight: extend this module (not
  `ContractMonitor`) once delta/DTE-target resolution has real chain
  data to resolve against.
  """

  require Logger

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.StrategyVersion

  @doc """
  Activates `version`: for each of its target pool's members, resolves a
  contract per `option_leg_config` and starts a `ContractMonitor` (a
  no-op if one is already running for that `{strategy_version_id,
  contract_key}` — mirrors `StrategyActivator`'s own `whereis/2`-before-
  start guard).

  Returns `{:error, reason}` if the version has no target pool or an
  unsupported `option_leg_config`.

  A monitor on the `:ibkr_live` pricing backend never fails to start
  over a failed real `trading_hub` subscribe RPC — see
  `TradingOptionsSim.Pricing.IBKRLive`'s moduledoc for why (matches
  `trading_live`'s own precedent: log and continue rather than fail
  closed). That means such a failure is otherwise invisible to an
  operator, so `activate/1` inspects every monitor it started via
  `ContractMonitor.snapshot/1` and returns
  `{:ok, pids, unsubscribed_symbols}` instead of plain `{:ok, pids}`
  whenever one or more came up without a live subscription —
  `unsubscribed_symbols` is `[]` in the common case.

  Note: `start_for_member/3` doesn't pass `pricing_backend`/`occ_symbol`
  yet — every monitor `activate/1` itself starts today runs
  `:black_scholes`, so `unsubscribed_symbols` is always `[]` in practice
  until this module is wired to select `:ibkr_live` (a separate,
  not-yet-scoped task; OCC symbol resolution already exists via
  `TradingOptionsSim.OccSymbol.build/4`). The plumbing here is in place
  ahead of that so switching the backend doesn't also require touching
  this return shape or its callers.
  """
  @spec activate(StrategyVersion.t()) ::
          {:ok, [pid()], [String.t()]}
          | {:error, :no_target_pool}
          | {:error, :unsupported_leg_config}
  def activate(%StrategyVersion{target_pool_id: nil}), do: {:error, :no_target_pool}

  def activate(%StrategyVersion{} = version) do
    with {:ok, contract_template} <- resolve_contract_template(version.option_leg_config) do
      pool = Sim.get_target_pool!(version.target_pool_id)

      pids =
        pool.target_pool_members
        |> Enum.map(&start_for_member(version, &1, contract_template))
        |> Enum.reject(&is_nil/1)

      unsubscribed_symbols =
        pids |> Enum.reject(&ibkr_live_subscribed?/1) |> Enum.map(&monitor_symbol/1)

      {:ok, _updated} = Sim.mark_activated(version)

      {:ok, pids, unsubscribed_symbols}
    end
  end

  defp ibkr_live_subscribed?(pid), do: ContractMonitor.snapshot(pid).ibkr_live_subscribed?

  defp monitor_symbol(pid), do: ContractMonitor.snapshot(pid).symbol

  @doc """
  Deactivates `version`: for every currently-open `SimRun` belonging to
  it, finds the running `ContractMonitor` (if any — a run with no
  running monitor is skipped, not an error, since that's already the
  effectively-deactivated state), flattens any open position via
  `ContractMonitor.force_close/2` (`reason: :manual` — matches
  `trading_live`'s own established convention: any operator-triggered
  close, via `StrategyStockMonitor.force_close_eod(pid, :manual)`, uses
  this exact reason regardless of whether it came from deactivate, kill,
  or kill_all; confirmed by reading that code directly rather than
  inventing a `trading_options_sim`-only name), and only once that
  synchronous call returns does it terminate the monitor's own
  `DynamicSupervisor` child — mirrors `trading_live`'s own
  `StrategyActivator.deactivate/1` sequencing (flatten, confirmed, *then*
  kill the process; never the reverse, which could kill a monitor
  mid-fill and leave a `SimRun` open with the DB never told).

  A run whose monitor never actually entered a position (still flat,
  watching) has no fill for `force_close/2` to flatten — `trading_live`
  has no equivalent case to port here (its own fill/order records only
  come into existence at the moment of a real fill, so a flat kill is a
  true no-op there with nothing to record; `SimRun` is architecturally
  different, pre-created at activation time before any entry). Left
  `"open"` forever, such a run's `SimRun.status` would keep claiming a
  monitor is running long after this function killed it — this is
  `deactivate/1`'s own decision, not a port: such a run is explicitly
  closed via `SimRun.close_without_entry_changeset/2` with
  `exit_reason: "manual_no_entry"` (never `"manual"` — that value is
  reserved for a real position that got flattened, per the fill-based
  reasons already in use: `"rule_exit"`, `"expiry"`, `"eod_flatten"`).

  Unlike `activate/1`, this never touches `lifecycle_stage` — a
  deactivated version stays at whatever stage it was (discovery,
  quarantine, test_portfolio); "activated" here means "has running
  monitors," a separate, orthogonal concept from lifecycle stage. Every
  `SimRun` reachable at all is closed either way (already-closed runs
  are `list_open_sim_runs/1`-filtered out), so re-`activate/1`ing later
  opens fresh runs rather than resuming stale ones.

  Returns `{:ok, terminated_count}` — always succeeds; there is no
  failure mode analogous to `activate/1`'s `:no_target_pool`/
  `:unsupported_leg_config`, since deactivating never needs to resolve
  a contract, only stop what's already running.
  """
  @spec deactivate(StrategyVersion.t()) :: {:ok, non_neg_integer()}
  def deactivate(%StrategyVersion{} = version) do
    open_runs = Sim.list_open_sim_runs(version)
    runs_by_symbol = Map.new(open_runs, &{&1.symbol, &1})
    contract_template = resolve_contract_template(version.option_leg_config)

    terminated_count =
      version
      |> monitored_symbols(runs_by_symbol, contract_template)
      |> Enum.map(fn symbol ->
        stop_monitor_for_symbol(
          version.id,
          symbol,
          Map.get(runs_by_symbol, symbol),
          contract_template
        )
      end)
      |> Enum.count(& &1)

    {:ok, _updated} = Sim.mark_deactivated(version)

    {:ok, terminated_count}
  end

  # Every symbol worth checking for a running monitor: every open run's
  # own symbol, plus (when the leg config resolves and a target pool is
  # set) every target-pool member's symbol — a flat-but-active monitor
  # has no open run to find it by, so deactivate/1 must also check by
  # resolved contract, same as StrategyVersionDetailLive's own fallback
  # (see that module's `build_member_entry/4`). Deliberately tolerant of
  # an unresolvable leg config or missing target pool (a version can
  # still be deactivated even if its own config has since become
  # invalid) — falls back to open-run symbols alone in that case.
  defp monitored_symbols(%{target_pool_id: nil}, runs_by_symbol, _contract_template) do
    Map.keys(runs_by_symbol)
  end

  defp monitored_symbols(_version, runs_by_symbol, {:error, :unsupported_leg_config}) do
    Map.keys(runs_by_symbol)
  end

  defp monitored_symbols(version, runs_by_symbol, {:ok, _template}) do
    member_symbols =
      version.target_pool_id
      |> Sim.get_target_pool!()
      |> Map.fetch!(:target_pool_members)
      |> Enum.map(& &1.symbol)

    (Map.keys(runs_by_symbol) ++ member_symbols) |> Enum.uniq()
  end

  defp stop_monitor_for_symbol(strategy_version_id, symbol, run, contract_template) do
    contract_key = symbol_contract_key(symbol, run, contract_template)

    case contract_key && ContractMonitor.whereis(strategy_version_id, contract_key) do
      nil ->
        false

      pid ->
        if run, do: flatten_and_close(pid, run)

        case DynamicSupervisor.terminate_child(TradingOptionsSim.MonitorSupervisor, pid) do
          :ok -> true
          {:error, :not_found} -> false
        end
    end
  end

  defp symbol_contract_key(symbol, %{} = run, _contract_template) do
    {symbol, run.expiry, run.strike, run.right}
  end

  defp symbol_contract_key(symbol, nil, {:ok, template}) do
    {symbol, template.expiry, template.strike, template.right}
  end

  defp symbol_contract_key(_symbol, nil, {:error, :unsupported_leg_config}), do: nil

  # snapshot/1 read BEFORE force_close/2 — force_close/2 flips
  # position_open? to false as a side effect of flattening, so checking
  # position_open? only after it ran could never distinguish "had a
  # position, now flattened" from "was always flat."
  defp flatten_and_close(pid, run) do
    position_was_open? = ContractMonitor.snapshot(pid).position_open?
    :ok = ContractMonitor.force_close(pid, :manual)

    unless position_was_open? do
      Sim.close_run_without_entry(run, "manual_no_entry")
    end
  catch
    # The monitor exited on its own between whereis/2 and this call (e.g.
    # it force-closed itself for DTE/EOD reasons at the same moment) —
    # nothing left to flatten or close; terminate_child/2's own caller
    # handles an already-gone pid via its {:error, :not_found} branch.
    :exit, _reason -> :ok
  end

  @doc """
  Resolves `option_leg_config` to a `%{expiry:, strike:, right:}`
  contract template — the same v1-only `"fixed_strike"`/`"fixed"`
  resolution `activate/1` itself uses, exposed publicly so
  `StrategyVersionDetailLive` can derive a member's contract identity
  without an open `SimRun` to read it from (needed to look up a
  monitor that's alive but flat — see `ContractMonitor.registry_key/2`'s
  own doc on why `SimRun`-derived contract fields alone aren't enough
  once a run has closed).
  """
  @spec resolve_contract_template(map()) ::
          {:ok, %{expiry: String.t(), strike: Decimal.t(), right: String.t()}}
          | {:error, :unsupported_leg_config}
  def resolve_contract_template(%{
        "expiry_selection" => expiry_selection,
        "fixed_expiry" => expiry,
        "strike_selection" => "fixed_strike",
        "fixed_strike" => strike,
        "right" => right
      })
      when expiry_selection in ["fixed", "leaps"] and right in ["C", "P"] do
    {:ok, %{expiry: expiry, strike: Decimal.new(to_string(strike)), right: right}}
  end

  def resolve_contract_template(_config), do: {:error, :unsupported_leg_config}

  defp start_for_member(version, member, contract_template) do
    contract_key =
      {member.symbol, contract_template.expiry, contract_template.strike, contract_template.right}

    open_runs = Sim.list_open_sim_runs(version)

    existing_run =
      Enum.find(open_runs, fn run ->
        {run.symbol, run.expiry, run.strike, run.right} == contract_key
      end)

    case existing_run do
      %{id: run_id} ->
        start_or_find_monitor(version, run_id, contract_key, member.exchange)

      nil ->
        start_new_run_and_monitor(version, member, contract_key)
    end
  end

  defp start_new_run_and_monitor(version, member, {symbol, expiry, strike, right}) do
    case Sim.open_sim_run(version, %{
           symbol: symbol,
           expiry: expiry,
           strike: strike,
           right: right,
           multiplier: 100,
           direction: version.direction
         }) do
      {:ok, run} ->
        start_or_find_monitor(version, run.id, {symbol, expiry, strike, right}, member.exchange)

      {:error, reason} ->
        Logger.error(
          "SimActivator: failed to open sim_run for #{version.id}/#{member.symbol}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp start_or_find_monitor(version, run_id, contract_key, exchange) do
    case ContractMonitor.whereis(version.id, contract_key) do
      nil ->
        spec = %{
          id: {run_id, contract_key},
          start:
            {ContractMonitor, :start_link,
             [
               [
                 exchange: exchange,
                 sim_run_id: run_id,
                 contract_key: contract_key,
                 strategy_version: version,
                 direction: version.direction,
                 quantity: 1
               ]
             ]},
          restart: :transient
        }

        case DynamicSupervisor.start_child(TradingOptionsSim.MonitorSupervisor, spec) do
          {:ok, pid} ->
            pid

          {:error, reason} ->
            Logger.error(
              "SimActivator: failed to start monitor for #{version.id}/#{inspect(contract_key)}: #{inspect(reason)}"
            )

            nil
        end

      pid ->
        pid
    end
  end
end
