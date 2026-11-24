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
  an already-running monitor for the same `{strategy_version_id,
  contract_key}`), so running it redundantly alongside the boot-time
  pass is safe.

  ## Releasing lines a previous process left on trading_hub

  A minute after each pass, `TradingOptionsSim.Pricing.HubLineSweep`
  releases this app's tag on hub option lines no local listener holds:
  an abrupt stop skips `IBKRLive.terminate/2`, so the old process's lines
  would otherwise stay subscribed forever.

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

  # Per-version retries after trading_hub failed to ANSWER a contract
  # lookup (SimActivator's :hub_unavailable) -- distinct from the
  # whole-pass retries above, which handle a pass that raised. Backoff
  # doubles from the base: 30s, 60s, 120s, 240s, 480s by default.
  @max_version_attempts 5
  @default_version_retry_base_ms 30_000

  # After a reactivation pass, the hub line sweep (HubLineSweep) runs this
  # much later. `config :trading_options_sim, :hub_line_sweep_delay_ms`
  # overrides it; `:disabled` turns it off.
  @default_line_sweep_delay_ms 60_000

  def start_link(_args \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Re-activates `version_id` later, with backoff, because some pool
  member's contract lookup went unanswered (a busy or unreachable hub),
  not because the contract doesn't exist. Called by
  `SimActivator.activate/1`. A no-op while a retry for that version is
  already pending, and a no-op when this process isn't running (tests
  run without it).
  """
  @spec retry_later(String.t()) :: :ok
  def retry_later(version_id), do: GenServer.cast(__MODULE__, {:retry_later, version_id})

  @impl true
  def init(_args) do
    {:ok, %{attempt: 1, trigger: :boot, pending: %{}}, {:continue, :reactivate}}
  end

  @impl true
  def handle_cast({:retry_later, version_id}, state) do
    pending = Map.get(state, :pending, %{})

    if Map.has_key?(pending, version_id) do
      {:noreply, state}
    else
      schedule_version_retry(version_id, 1)
      {:noreply, Map.put(state, :pending, Map.put(pending, version_id, 1))}
    end
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

  # Best effort: a sweep that raises is logged, never allowed to restart
  # this process (and with it a whole reactivation pass).
  def handle_info(:sweep_hub_lines, state) do
    _ = TradingOptionsSim.Pricing.HubLineSweep.release_orphans()
    {:noreply, state}
  rescue
    error ->
      Logger.warning("SimReactivator: hub line sweep raised #{Exception.message(error)}")
      {:noreply, state}
  end

  def handle_info({:retry_version, version_id}, state) do
    pending = Map.get(state, :pending, %{})
    attempt = Map.get(pending, version_id, 1)
    pending = Map.delete(pending, version_id)

    pending =
      case retry_version(version_id) do
        :done ->
          pending

        :still_unanswered when attempt < @max_version_attempts ->
          schedule_version_retry(version_id, attempt + 1)
          Map.put(pending, version_id, attempt + 1)

        :still_unanswered ->
          Logger.error(
            "SimReactivator: contract lookups for version #{version_id} still unanswered " <>
              "after #{@max_version_attempts} retries -- giving up; re-activate it manually"
          )

          pending
      end

    {:noreply, Map.put(state, :pending, pending)}
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

  # :done once no member is left unanswered -- or the version was
  # deactivated or deleted meanwhile, when there's nothing to retry.
  defp retry_version(version_id) do
    version = TradingOptionsSim.Repo.get(TradingOptionsSim.Sim.StrategyVersion, version_id)

    # Gone, deactivated or soft-deleted meanwhile: nothing to retry. (A
    # hard delete used to raise here and be counted as "still
    # unanswered" until the retries ran out.)
    if is_nil(version) or is_nil(version.activated_at) or not is_nil(version.deactivated_at) or
         not is_nil(version.deleted_at) do
      :done
    else
      case SimActivator.activate_report(version) do
        {:ok, _pids, _unsubscribed, []} ->
          Logger.info("SimReactivator: version #{version_id} fully activated on retry")
          :done

        {:ok, _pids, _unsubscribed, _transient} ->
          :still_unanswered

        {:error, _reason} ->
          :done
      end
    end
  rescue
    error ->
      Logger.warning("SimReactivator: retry of #{version_id} raised #{inspect(error)}")
      :still_unanswered
  end

  # Release hub option lines a previous process left behind (see
  # HubLineSweep). Delayed so the hub isn't asked while every listener is
  # still pinning its contract; listeners are registered by then, since
  # activate/1 starts them synchronously. Only one sweep is pending at a
  # time: a second pass inside the delay reuses it.
  defp schedule_line_sweep do
    delay =
      Application.get_env(
        :trading_options_sim,
        :hub_line_sweep_delay_ms,
        @default_line_sweep_delay_ms
      )

    case Process.get(:hub_line_sweep_timer) do
      ref when is_reference(ref) ->
        if Process.read_timer(ref), do: :ok, else: start_line_sweep_timer(delay)

      _ ->
        start_line_sweep_timer(delay)
    end
  end

  # Never raises: a bad setting must not fail the reactivation pass it
  # runs in. Anything but a non-negative integer (or :disabled) is
  # treated as unset.
  defp start_line_sweep_timer(:disabled), do: :ok

  defp start_line_sweep_timer(delay) when is_integer(delay) and delay >= 0 do
    Process.put(:hub_line_sweep_timer, Process.send_after(self(), :sweep_hub_lines, delay))
  end

  defp start_line_sweep_timer(_invalid), do: start_line_sweep_timer(@default_line_sweep_delay_ms)

  defp schedule_version_retry(version_id, attempt) do
    base =
      Application.get_env(
        :trading_options_sim,
        :version_retry_base_ms,
        @default_version_retry_base_ms
      )

    Process.send_after(self(), {:retry_version, version_id}, base * Integer.pow(2, attempt - 1))
  end

  defp do_reactivate(state) do
    versions = Sim.list_active_strategy_versions()

    Logger.info(
      "SimReactivator: reactivating monitors for #{length(versions)} active strategy versions " <>
        "(trigger: #{state.trigger}, attempt #{state.attempt}/#{@max_attempts})"
    )

    Enum.each(versions, &SimActivator.activate/1)
    schedule_line_sweep()

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
