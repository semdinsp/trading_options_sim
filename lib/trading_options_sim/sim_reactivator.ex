defmodule TradingOptionsSim.SimReactivator do
  @moduledoc """
  Restarts `ContractMonitor`s for every `StrategyVersion` with at least
  one open `SimRun` on application start, AND again any time
  `TradingOptionsSim.MonitorSupervisor` itself restarts thereafter —
  ported near-verbatim from `trading_live`'s own `StrategyReactivator`
  (confirmed by reading that module directly), adapted to this app's
  `SimActivator`/`SimRun` shape.

  `SimActivator.activate/1` is otherwise only called from a manual
  dashboard action — `ContractMonitor`s are in-memory `DynamicSupervisor`
  children with no persistence of their own, so without this, any
  restart (crash, deploy, or a plain `mix phx.server` restart) silently
  drops every active strategy's monitors while its `SimRun`s stay
  "open" in the DB forever: no ticks get evaluated, nothing ever exits
  the position, and nothing logs an error because there's no crash,
  just an empty `MonitorSupervisor` — confirmed live 2026-09-15: two
  activated SPY option strategies sat with open runs and zero running
  monitors for hours across two separate `iex -S mix phx.server`
  restarts during this same session, discovered only because the new
  `StrategyVersionDetailLive` page showed "Not running" for a version
  the list pages still called "Active".

  ## Reacting to a MonitorSupervisor restart, not just app boot

  A one-shot boot task only covers a *new* `trading_options_sim`
  process starting fresh. It does NOT cover `MonitorSupervisor` itself
  crashing and restarting mid-run while the app keeps running — see
  `trading_live.StrategyReactivator`'s own moduledoc for the exact
  incident that made this matter there (a burst of monitor crashes
  exceeding the supervisor's restart intensity, wiping every monitor at
  once with the boot-time pass having already run hours earlier).
  Handled the identical way: monitor `MonitorSupervisor`'s pid
  (`Process.monitor/1`, re-armed after every `:DOWN`) and re-run the
  same reactivation pass whenever it goes down — `SimActivator.activate/1`
  is idempotent (guarded by `ContractMonitor.whereis/2`, a no-op against
  an already-running monitor for the same `{sim_run_id, contract_key}`),
  so running it redundantly alongside the boot-time pass is safe.

  ## Retry on failure

  Each reactivation pass is wrapped in `rescue`/`catch` and retried up
  to `@max_attempts` times with a short fixed delay — matches
  `trading_live`'s own reasoning: for the boot-time pass specifically
  (running inside `init/1` via `handle_continue/2`), an uncaught
  exception would either crash-loop the whole app supervision tree, or
  succeed silently on the supervisor's own automatic restart with no
  log explaining why the first attempt failed. After `@max_attempts`
  failures, logs at `:error` and gives up — an operator can always fall
  back to `StrategyVersionsLive`'s per-version Activate button, which
  this module itself calls through `SimActivator.activate/1`.
  """

  use GenServer
  require Logger

  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.SimActivator

  @max_attempts 5
  @retry_delay_ms 2_000

  def start_link(_args \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_args) do
    {:ok, %{attempt: 1, trigger: :boot}, {:continue, :reactivate}}
  end

  @impl true
  def handle_continue(:reactivate, state) do
    monitor_supervisor()
    do_reactivate(state)
  end

  @impl true
  def handle_info({:retry, attempt}, state) do
    do_reactivate(%{state | attempt: attempt})
  end

  # MonitorSupervisor restarted (crash, or its own restart-intensity
  # limit was exceeded and TradingOptionsSim.Supervisor brought it back
  # empty — see this module's own moduledoc) — treat it exactly like a
  # fresh boot: every dynamically-started child it had is gone, nothing
  # else repopulates it.
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, _state) do
    Logger.warning(
      "SimReactivator: MonitorSupervisor went down (#{inspect(reason)}) — " <>
        "reactivating all active strategy versions' monitors"
    )

    monitor_supervisor()
    do_reactivate(%{attempt: 1, trigger: :supervisor_restart})
  end

  defp monitor_supervisor do
    case Process.whereis(TradingOptionsSim.MonitorSupervisor) do
      nil ->
        # Not started yet in this app's supervision order — retried via
        # the same {:retry, _} path a reactivation failure already uses.
        Process.send_after(self(), {:retry, 1}, @retry_delay_ms)

      pid ->
        Process.monitor(pid)
    end
  end

  defp do_reactivate(state) do
    versions = Sim.list_active_strategy_versions()

    Logger.info(
      "SimReactivator: reactivating monitors for #{length(versions)} active strategy versions " <>
        "(trigger: #{state.trigger}, attempt #{state.attempt}/#{@max_attempts})"
    )

    Enum.each(versions, &SimActivator.activate/1)

    {:noreply, state}
  rescue
    error -> handle_failure(state, Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, reason -> handle_failure(state, Exception.format(kind, reason, __STACKTRACE__))
  end

  defp handle_failure(state, formatted_error) do
    if state.attempt < @max_attempts do
      Logger.warning(
        "SimReactivator: reactivation attempt #{state.attempt}/#{@max_attempts} failed, " <>
          "retrying in #{@retry_delay_ms}ms: #{formatted_error}"
      )

      Process.send_after(self(), {:retry, state.attempt + 1}, @retry_delay_ms)
      {:noreply, state}
    else
      Logger.error(
        "SimReactivator: reactivation failed after #{@max_attempts} attempts, giving up " <>
          "— use StrategyVersionsLive's per-version Activate button to recover manually: " <>
          formatted_error
      )

      {:noreply, state}
    end
  end
end
