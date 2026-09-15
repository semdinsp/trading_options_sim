defmodule TradingOptionsSim.EodCloser do
  @moduledoc """
  Periodic GenServer that force-closes every open position within its
  own exchange's `ExchangeTradingHours.close_before_minutes` (11 by
  default) of that exchange's close — ported from `TradingLive.EodCloser`
  per `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §5c, scoped down: no
  `overnight_hold`/`time_box_exit_et`/`close_after_hours` equivalent
  exists in this app yet, so every open position is force-closed
  unconditionally near its exchange's close in v1.

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

  alias TradingOptionsSim.ExchangeSessionCache
  alias TradingOptionsSim.Sim

  @default_tick_interval_ms 60_000
  @default_close_before_ms 11 * 60 * 1000

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
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    do_scan()
    schedule_next()
    {:noreply, state}
  end

  @impl true
  def handle_call(:run_once, _from, state) do
    do_scan()
    {:reply, :ok, state}
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

  defp do_scan do
    now = DateTime.utc_now()

    running_monitors()
    |> Enum.each(fn {strategy_version_id, pid} ->
      maybe_close_isolated(strategy_version_id, pid, now)
    end)
  rescue
    error ->
      Logger.error("EodCloser: scan pass failed: #{inspect(error)}")
  end

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

      %{exchange: exchange} ->
        case ExchangeSessionCache.fetch(exchange) do
          nil ->
            :ok

          session ->
            if within_close_window?(session, now, exchange) do
              Logger.info(
                "EodCloser: forcing EOD close for strategy_version #{strategy_version_id} (#{exchange} closes soon)"
              )

              send(pid, {:force_close_eod, :eod_flatten})
            end
        end
    end
  end

  defp fetch_snapshot(pid) do
    TradingOptionsSim.ContractMonitor.snapshot(pid)
  catch
    :exit, _reason -> %{position_open?: false, exchange: nil}
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
