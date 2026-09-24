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
  alias TradingOptionsSim.ContractSelector
  alias TradingOptionsSim.Pricing.PolygonSubscription
  alias TradingOptionsSim.Pricing.UnderlyingSubscription
  alias TradingOptionsSim.PolygonRelay
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.SimRun
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

  The backend comes from `pricing_opts/1`, driven by the
  `:pricing_backend` app env (default `:black_scholes`). With
  `:ibkr_live` configured, each monitor gets a real
  `TradingOptionsSim.OccSymbol.build/4` symbol and subscribes to
  trading_hub's option ticks, so `unsubscribed_symbols` reports the
  contracts whose subscription did not come up. Under `:black_scholes`
  every monitor prices synthetically, never subscribes, and
  `unsubscribed_symbols` is therefore always `[]` — that was the only
  behavior available before 2026-09-17, and it is why a fill recorded
  then shows `fill_basis: "model_price"`: a synthetic price has no
  bid/ask for `ContractMonitor.fill_price_for/4` to fill against.
  """
  @spec activate(StrategyVersion.t()) ::
          {:ok, [pid()], [String.t()]}
          | {:error, :no_target_pool}
          | {:error, :unsupported_leg_config}
  def activate(%StrategyVersion{target_pool_id: nil}), do: {:error, :no_target_pool}

  def activate(%StrategyVersion{} = version) do
    with :ok <- validate_leg_config(version.option_leg_config) do
      pool = Sim.get_target_pool!(version.target_pool_id)

      pids =
        pool.target_pool_members
        |> Enum.map(&start_for_resolved_member(version, &1))
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

    # Found through the registry, not rebuilt from the leg config or the
    # open runs: for atm_offset neither names the contract a monitor is
    # actually on, so the old lookup missed running monitors and left
    # them trading after "deactivate".
    terminated_count =
      version.id
      |> ContractMonitor.monitors_for_version()
      |> Enum.count(fn {_symbol, pid} -> stop_monitor(pid, open_runs) end)

    # Release this version's hold on each underlying. Reference-counted,
    # so a symbol another active strategy still needs keeps its
    # subscription -- only the last release actually unsubscribes.
    # Without this, every deactivate/reactivate cycle would leak an IBKR
    # market-data line until trading_hub itself restarted.
    release_underlyings(version)

    {:ok, _updated} = Sim.mark_deactivated(version)

    {:ok, terminated_count}
  end

  defp release_underlyings(%StrategyVersion{target_pool_id: nil}), do: :ok

  defp release_underlyings(%StrategyVersion{} = version) do
    version.target_pool_id
    |> Sim.get_target_pool!()
    |> Map.fetch!(:target_pool_members)
    |> Enum.each(fn member ->
      UnderlyingSubscription.release(member.symbol)
      PolygonSubscription.release(member.symbol)
    end)
  end

  # Flattens pid's position (closing its run) and terminates it. The run
  # is matched on the monitor's OWN contract, read from its snapshot.
  defp stop_monitor(pid, open_runs) do
    run =
      case safe_snapshot(pid) do
        %{} = snap ->
          Enum.find(open_runs, &same_contract?(&1, snap))

        nil ->
          nil
      end

    if run, do: flatten_and_close(pid, run)

    case DynamicSupervisor.terminate_child(TradingOptionsSim.MonitorSupervisor, pid) do
      :ok -> true
      {:error, :not_found} -> false
    end
  end

  @doc false
  # Decimal.equal?, not ==: the same strike can carry a different scale
  # depending on where it was read from ("735.0" vs "735.00").
  def same_contract?(a, b) do
    a.symbol == b.symbol and a.expiry == b.expiry and a.right == b.right and
      Decimal.equal?(a.strike, b.strike)
  end

  defp safe_snapshot(pid) do
    ContractMonitor.snapshot(pid)
  catch
    :exit, _ -> nil
  end

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

  # Resolves the contract PER MEMBER, then starts a monitor for it.
  #
  # This is the seam that makes a multi-symbol strategy possible. A
  # fixed_strike config resolves to the same literal contract for every
  # member (the pre-existing behaviour, unchanged), but an atm_offset
  # config resolves against each symbol's own spot -- so one strategy
  # over a pool of {SPY, QQQ, IWM} produces three genuinely
  # at-the-money contracts rather than one usable strike and two
  # nonsense ones.
  #
  # A member that cannot be resolved is skipped with a log line rather
  # than failing the whole activation: one symbol lacking a listing at
  # the requested expiry should not prevent the other symbols in the
  # pool from trading. Fails closed per-member, not per-strategy.
  defp start_for_resolved_member(version, member) do
    # Subscribe the UNDERLYING before resolving a contract against it.
    # ContractSelector reads spot from trading_hub, so an unsubscribed
    # symbol returns {:error, :no_spot} and the member is skipped -- which
    # is exactly what happened to QQQ across three restarts, and what made
    # XLK/XLF permanently unusable since no sibling app tracks them.
    #
    # Reference-counted (see UnderlyingSubscription): several members and
    # several strategies on one symbol share a single hub subscription,
    # released only when the last one detaches.
    ensure_underlying(member)
    ensure_polygon(member)

    case open_run_for_symbol(version, member.symbol) do
      %SimRun{} = run -> resume_run(version, member, run)
      nil -> resolve_and_start(version, member)
    end
  end

  # An open run means this symbol already has a contract (and possibly
  # a position) in flight, so RESUME it rather than resolving ATM again.
  #
  # Re-resolving is what orphaned runs until 2026-09-24: for an
  # atm_offset version the strike follows spot, so every restart after
  # the underlying had moved a strike picked a new contract, opened a
  # new run and monitor beside it, and left the old run open with
  # nothing watching it -- 154 of 243 open runs, 45 of them holding a
  # position that would never be exited or scored.
  #
  # With several open runs for one symbol (only possible from that old
  # bug), prefer one holding a position, then the newest.
  defp open_run_for_symbol(version, symbol) do
    version
    |> Sim.list_open_sim_runs()
    |> Enum.filter(&(&1.symbol == symbol))
    # A plain term sort on a DateTime compares struct fields, not time,
    # so order on the unix timestamp.
    |> Enum.sort_by(
      &{not is_nil(&1.entry_at), DateTime.to_unix(&1.inserted_at, :microsecond)},
      :desc
    )
    |> List.first()
  end

  defp resume_run(version, member, run) do
    start_or_find_monitor(
      version,
      run,
      {run.symbol, run.expiry, run.strike, run.right},
      member.exchange
    )
  end

  defp resolve_and_start(version, member) do
    case resolve_for_symbol(member.symbol, version.option_leg_config) do
      {:ok, contract_template} ->
        start_for_member(version, member, contract_template)

      {:error, reason} ->
        Logger.warning(
          "SimActivator: skipping #{member.symbol} for version #{version.id} — " <>
            "could not resolve a listed contract (#{inspect(reason)})"
        )

        nil
    end
  end

  # A failed subscribe is logged inside UnderlyingSubscription and is
  # NOT fatal: resolution may still succeed if another app already holds
  # the symbol, and a strategy must not fail to activate because one hub
  # RPC was unlucky. The :no_spot path below is the real gate.
  defp ensure_underlying(member) do
    UnderlyingSubscription.ensure(member.symbol,
      exchange: member.exchange,
      currency: member.currency || "USD"
    )
  catch
    :exit, reason ->
      Logger.warning(
        "SimActivator: underlying subscribe for #{member.symbol} failed: #{inspect(reason)}"
      )

      {:ok, false}
  end

  # The underlying's Polygon trades/quotes/minute bars, which is where
  # volume and a sized two-sided quote come from (IBKR's prices:SYMBOL
  # carries neither). Two steps, both needed: ensure/2 asks the hub to
  # stream the symbol, watch/1 makes PolygonRelay listen and fold it
  # into PolygonFeatures -- the run_poly_* keys ContractMonitor merges
  # into every rule snapshot. Non-fatal for the same reason as
  # ensure_underlying/1: a rule on a run_poly_* key simply fails closed
  # while the data is absent, and nothing else depends on it.
  defp ensure_polygon(member) do
    PolygonRelay.watch(member.symbol)
    PolygonSubscription.ensure(member.symbol)
  catch
    :exit, reason ->
      Logger.warning(
        "SimActivator: polygon subscribe for #{member.symbol} failed: #{inspect(reason)}"
      )

      {:ok, false}
  end

  defp resolve_for_symbol(symbol, %{"strike_selection" => "atm_offset"} = config) do
    ContractSelector.resolve(symbol, config)
  end

  defp resolve_for_symbol(_symbol, config), do: resolve_contract_template(config)

  # Cheap up-front check so an unsupported config fails before a pool
  # lookup and a round of hub RPCs. atm_offset is validated per symbol
  # in ContractSelector; everything else goes through the literal
  # template resolver.
  defp validate_leg_config(%{"strike_selection" => "atm_offset"}), do: :ok

  defp validate_leg_config(config) do
    case resolve_contract_template(config) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_for_member(version, member, contract_template) do
    contract_key =
      {member.symbol, contract_template.expiry, contract_template.strike, contract_template.right}

    open_runs = Sim.list_open_sim_runs(version)

    existing_run =
      Enum.find(open_runs, fn run ->
        {run.symbol, run.expiry, run.strike, run.right} == contract_key
      end)

    case existing_run do
      %SimRun{} = run ->
        start_or_find_monitor(version, run, contract_key, member.exchange)

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
        start_or_find_monitor(version, run, {symbol, expiry, strike, right}, member.exchange)

      {:error, reason} ->
        Logger.error(
          "SimActivator: failed to open sim_run for #{version.id}/#{member.symbol}: #{inspect(reason)}"
        )

        nil
    end
  end

  # The run's own position state goes to the monitor. Without it a
  # resumed monitor started flat whatever the run held, and its next
  # entry signal wrote a SECOND entry fill into the same run,
  # overwriting entry_price/entry_at: 48 runs carried 248 extra entry
  # fills (2026-09-18 to 09-24) before this was fixed.
  defp start_or_find_monitor(version, %SimRun{id: run_id} = run, contract_key, exchange) do
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
                 quantity: 1,
                 position_open?: not is_nil(run.entry_at),
                 entered_at: run.entry_at
               ] ++ pricing_opts(contract_key)
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
        # Reusing an already-running monitor (this contract's own
        # long-lived process — see ContractMonitor.registry_key/2's own
        # doc on why one can outlive any single SimRun) for `run_id` —
        # update_sim_run_id/2 is the fix for a real, confirmed-live bug:
        # without this, the monitor kept writing every subsequent
        # entry/exit onto whatever run it was originally started with,
        # silently corrupting an old, already-closed run's row instead
        # of the new one SimActivator just opened (or found). See that
        # function's own doc for the full incident.
        :ok = ContractMonitor.update_sim_run_id(pid, run_id)
        pid
    end
  end

  # Selects the pricing backend for a monitor this module starts.
  #
  # `:ibkr_live` prices from trading_hub's real option ticks (and is the
  # only backend that can ever see a two-sided quote, which
  # `ContractMonitor.fill_price_for/4` needs to fill at the touch rather
  # than at a model mid). `:black_scholes` is synthetic: a flat-IV
  # theoretical price with no bid/ask at all.
  #
  # Gated on `:pricing_backend` config rather than hardcoded so this can
  # be rolled back without a code change, and so `:test` keeps using
  # `:black_scholes` (no trading_hub node exists there — see
  # `Application.hub_client_children/0`'s own test-env skip).
  #
  # `ContractMonitor.init/1` raises if `:ibkr_live` arrives without an
  # `:occ_symbol`, so the symbol is always built here, never left for
  # the caller to remember.
  defp pricing_opts({symbol, expiry, strike, right}) do
    case Application.get_env(:trading_options_sim, :pricing_backend, :black_scholes) do
      :ibkr_live ->
        [
          pricing_backend: :ibkr_live,
          occ_symbol: TradingOptionsSim.OccSymbol.build(symbol, expiry, strike, right)
        ]

      _other ->
        [pricing_backend: :black_scholes]
    end
  end
end
