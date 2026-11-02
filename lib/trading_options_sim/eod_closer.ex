defmodule TradingOptionsSim.EodCloser do
  @moduledoc """
  Periodic GenServer that force-closes every open position within its
  own exchange's `ExchangeTradingHours.close_before_minutes` (11 by
  default) of that exchange's close — ported from `TradingLive.EodCloser`
  per `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §5c.

  A `StrategyVersion` with `overnight_hold: true` is exempt from this
  automatic close (see `overnight_hold?/1`'s own doc) — no
  `time_box_exit_et`/`close_after_hours` equivalent exists in this app
  yet, so those two trading_live-specific exemptions have no analog
  here.

  Runs every `@tick_interval_ms` (60s by default). Each tick, scans
  every running `ContractMonitor` via the `MonitorRegistry`, reads its
  `snapshot/1` (open position?, exchange), and for any monitor with an
  open position whose exchange session's `TradingCore.MarketHours.next_close/2`
  falls within the close-before window, sends it `{:force_close_eod,
  :eod_flatten}` — the monitor itself (not this process) records the
  actual exit fill, via the same `submit_exit/3` path every other exit
  already uses (see `ContractMonitor`'s own `handle_info({:force_close_eod,
  reason}, state)` clause).

  A monitor with an unresolvable exchange (`nil`, or no mapped
  `ExchangeSession`) is silently skipped — same fail-closed convention
  `ContractMonitor.session_open?/1` already uses; this process only ever
  *asks* a monitor to close, it never assumes an exchange is open on its
  own.
  """

  use GenServer
  require Logger

  alias TradingOptionsSim.{ComboMonitor, ContractMonitor, ExchangeSessionCache, SimActivator}
  alias TradingOptionsSim.Sim

  @default_tick_interval_ms 60_000
  @default_close_before_ms 11 * 60 * 1000
  # A run entered this recently may belong to a monitor whose snapshot
  # was read just before the entry; leave it to the next tick.
  @orphan_grace_seconds 120

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Runs one close-scan pass immediately, outside the periodic schedule — used by tests and manual triggers."
  @spec run_once :: :ok
  def run_once do
    GenServer.call(__MODULE__, :run_once, 30_000)
  end

  @impl true
  def init(_opts) do
    schedule_next()
    {:ok, %{reported_orphans: MapSet.new()}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = do_scan(state)
    schedule_next()
    {:noreply, state}
  end

  @impl true
  def handle_call(:run_once, _from, state) do
    {:reply, :ok, do_scan(state)}
  end

  defp schedule_next do
    interval =
      Application.get_env(
        :trading_options_sim,
        :eod_closer_tick_interval_ms,
        @default_tick_interval_ms
      )

    Process.send_after(self(), :tick, interval)
  end

  defp do_scan(state) do
    now = DateTime.utc_now()
    monitors = running_monitors()

    Enum.each(monitors, fn {strategy_version_id, pid} ->
      maybe_close_isolated(strategy_version_id, pid, now)
    end)

    adopt_orphaned_runs(state, monitors, now)
  rescue
    error ->
      Logger.error("EodCloser: scan pass failed: #{inspect(error)}")
      state
  end

  # This module flattens positions by asking monitors, so an open run no
  # monitor holds is never closed: on 2026-11-02 six monitors crashed
  # mid-position and restarted flat, and their runs stayed open past the
  # close. Each tick, every open run with an entry that no running
  # monitor reports holding is handed back:
  #   * to its own monitor if one is running (it re-reads the run and
  #     takes it over, see ContractMonitor's :adopt_open_run clause);
  #   * otherwise, for an active version, by re-activating it once, which
  #     resumes open runs (SimActivator.activate/1);
  #   * a run of an inactive version is logged once.
  # A run still unheld after that is left for the close routine
  # (CLAUDEDAILY.md C0) to report, not re-activated every minute.
  # Once held, the next tick closes it like any other position.
  defp adopt_orphaned_runs(state, monitors, now) do
    held =
      monitors
      |> Enum.flat_map(fn {_version_id, pid} ->
        case fetch_snapshot(pid) do
          %{position_open?: true, sim_run_id: run_id} -> [run_id]
          _ -> []
        end
      end)
      |> MapSet.new()

    orphans =
      now
      |> DateTime.add(-@orphan_grace_seconds, :second)
      |> Sim.list_open_entered_runs()
      |> Enum.reject(&MapSet.member?(held, &1.id))

    active_ids = MapSet.new(Sim.list_active_strategy_versions(), & &1.id)

    {reported, _reactivated} =
      Enum.reduce(orphans, {state.reported_orphans, MapSet.new()}, fn run, acc ->
        adopt(run, active_ids, acc)
      end)

    %{state | reported_orphans: reported}
  end

  defp adopt(run, active_ids, {reported, reactivated}) do
    version_id = run.strategy_version_id

    cond do
      pid = orphan_monitor(run) ->
        Logger.warning(
          "EodCloser: open run #{run.id} (#{version_id} #{run.symbol}) is held by no monitor; " <>
            "asking its monitor to take it over"
        )

        send(pid, :adopt_open_run)
        {reported, reactivated}

      MapSet.member?(reactivated, version_id) or MapSet.member?(reported, run.id) ->
        {reported, reactivated}

      MapSet.member?(active_ids, version_id) ->
        Logger.warning(
          "EodCloser: open run #{run.id} (#{version_id} #{run.symbol}) has no monitor; " <>
            "re-activating its version to resume it"
        )

        SimActivator.activate(Sim.get_strategy_version!(version_id))
        {MapSet.put(reported, run.id), MapSet.put(reactivated, version_id)}

      true ->
        Logger.error(
          "EodCloser: open run #{run.id} (#{version_id} #{run.symbol}) belongs to an " <>
            "inactive version and no monitor holds it; it will not be closed automatically"
        )

        {MapSet.put(reported, run.id), reactivated}
    end
  end

  defp orphan_monitor(%{structure: nil} = run),
    do:
      ContractMonitor.whereis(
        run.strategy_version_id,
        {run.symbol, run.expiry, run.strike, run.right}
      )

  defp orphan_monitor(run), do: ComboMonitor.whereis(run.strategy_version_id, run.symbol)

  # MonitorRegistry is shared with TradingOptionsSim.Pricing.IBKRLive,
  # whose own keys are {:ibkr_live, occ_symbol} — also a 2-tuple, so a
  # plain {:"$1", :_} pattern here matched those too and crashed every
  # running IBKRLive listener on each tick (it has no handle_call(:snapshot,
  # ...) clause; confirmed live via mix test — the process gets restarted
  # by its :transient child spec, but the crash itself is real and pointless).
  # ContractMonitor's own registry key is always {strategy_version_id,
  # contract_key_string} — strategy_version_id a binary (UUIDv7 string,
  # see registry_key/2); IBKRLive's own first element is always the atom
  # :ibkr_live — the is_binary/1 guard is what actually discriminates the
  # two key shapes sharing this registry, not the tuple arity.
  defp running_monitors do
    Registry.select(TradingOptionsSim.MonitorRegistry, [
      {{{:"$1", :_}, :"$2", :_}, [{:is_binary, :"$1"}], [{{:"$1", :"$2"}}]}
    ])
  end

  # One monitor raising (stale/crashed pid, unexpected snapshot shape)
  # must not abort the rest of this tick's scan.
  defp maybe_close_isolated(strategy_version_id, pid, now) do
    maybe_close(strategy_version_id, pid, now)
  rescue
    error ->
      Logger.error(
        "EodCloser: scan of strategy_version #{strategy_version_id} failed: #{inspect(error)} — continuing scan for remaining monitors"
      )
  end

  defp maybe_close(strategy_version_id, pid, now) do
    case fetch_snapshot(pid) do
      %{position_open?: false} ->
        :ok

      %{exchange: nil} ->
        :ok

      %{exchange: exchange} = snapshot ->
        case ExchangeSessionCache.fetch(exchange) do
          nil ->
            :ok

          session ->
            cond do
              not within_close_window?(session, now, exchange) ->
                :ok

              # A contract inside its expiry window closes today whatever
              # overnight_hold says: holding it would carry it into expiry
              # day. Matches trading_live's 1-DTE close (D3).
              expiring?(snapshot) ->
                Logger.info(
                  "EodCloser: closing strategy_version #{strategy_version_id} #{snapshot.symbol} #{snapshot.expiry} — inside its expiry window"
                )

                send(pid, {:force_close_eod, :expiry})

              overnight_hold?(strategy_version_id) ->
                Logger.info(
                  "EodCloser: #{strategy_version_id} would normally force-close near #{exchange}'s close, but overnight_hold is set — leaving it open"
                )

              true ->
                Logger.info(
                  "EodCloser: forcing EOD close for strategy_version #{strategy_version_id} (#{exchange} closes soon)"
                )

                send(pid, {:force_close_eod, :eod_flatten})
            end
        end
    end
  end

  # Ported from trading_live's own overnight_hold exemption
  # (confirmed by reading TradingLive.EodCloser directly) — suppresses
  # ONLY this automatic EOD force-close, never a manual flatten
  # (Sim.deactivate_strategy_version/1 calls ContractMonitor.force_close/2
  # directly, bypassing this module entirely, same "manual always
  # overrides the automatic exemption" posture trading_live's own
  # moduledoc documents). Read fresh per tick rather than cached on
  # ContractMonitor's own state — unlike trading_live, which applies a
  # live toggle via PubSub to an already-running monitor, this app's
  # EodCloser already re-scans every open position every tick, so a
  # flag change is naturally picked up on the very next scan with no
  # extra plumbing needed.
  defp overnight_hold?(strategy_version_id) do
    Sim.get_strategy_version!(strategy_version_id).overnight_hold
  end

  defp expiring?(%{expiry: expiry, expiry_close_dte: cutoff})
       when is_binary(expiry) and is_integer(cutoff),
       do: TradingOptionsSim.ContractMonitor.days_to_expiry(expiry) <= cutoff

  defp expiring?(_snapshot), do: false

  defp fetch_snapshot(pid) do
    TradingOptionsSim.ContractMonitor.snapshot(pid)
  catch
    :exit, _reason -> %{position_open?: false, exchange: nil}
  end

  @doc """
  True when `exchange` is within its configured close-before window
  (`close_before_minutes`, 11 by default) of today's close -- the window
  in which this module flattens positions. `ContractMonitor` asks the
  same question before an ENTRY, so a monitor never opens a position
  this module would flatten a minute later. An exchange that is nil or
  unmapped is never "in the window" (fails open, like
  `ContractMonitor.session_open?/1` for a nil exchange).
  """
  @spec in_close_window?(String.t() | nil, DateTime.t()) :: boolean()
  def in_close_window?(nil, _now), do: false

  def in_close_window?(exchange, now) do
    case ExchangeSessionCache.fetch(exchange) do
      nil -> false
      session -> within_close_window?(session, now, exchange)
    end
  end

  defp within_close_window?(session, now, exchange) do
    case TradingCore.MarketHours.next_close(session, now) do
      nil ->
        false

      next_close ->
        DateTime.diff(next_close, now, :millisecond) <= close_before_ms(exchange)
    end
  end

  defp close_before_ms(exchange) do
    case Sim.get_close_before_minutes(exchange) do
      nil -> @default_close_before_ms
      minutes -> minutes * 60 * 1000
    end
  end
end
