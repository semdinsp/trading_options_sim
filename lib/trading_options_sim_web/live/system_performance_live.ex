defmodule TradingOptionsSimWeb.SystemPerformanceLive do
  @moduledoc """
  `/system-performance` — operational health for the running node.
  Ported down from `trading_system`'s `SystemPerformanceLive`, scoped to
  what this app actually has: no EntryEvaluator, no per-strategy open
  position cap, no quarantine day-count staleness rollup (this app's own
  `QuarantineEligibilityWorker` is one daily Oban job, not eleven), no
  LiveStrategy market-open-reactivation concept.

  * **Node Health** — uptime, DB, `trading_hub` connection, `trading_signal`
    connection, active `ContractMonitor` count, process count/limit.
    Backed by `AppStatus.Collector.get/0`, the same cached report `/status`
    already serves — this page just surfaces it in the UI. A low uptime
    on a node that's supposed to stay up means it crashed and just
    restarted — every cron-driven safety net (`QuarantineEligibilityWorker`,
    `EodCloser`) missed however long the gap was, same reasoning
    `trading_system`'s identical panel documents.
  * **Cron / Oban Health** — this app's one cron worker
    (`QuarantineEligibilityWorker`), same shape as `trading_system`'s
    panel: last job (any state), last two successful completions, and a
    pending-job count across all queues.
  """

  use TradingOptionsSimWeb, :live_view

  alias TradingOptionsSim.Sim

  @poll_ms 5_000
  @uptime_warning_seconds 3_600

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@poll_ms, self(), :refresh)

    {:ok, socket |> assign(:page_title, "System Performance") |> assign_all()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign_all(socket)}
  end

  defp assign_all(socket) do
    socket
    |> assign(:report, AppStatus.Collector.get())
    |> assign(:cron_workers, Sim.cron_worker_health())
    |> assign(:pending_count, Sim.oban_pending_job_count())
    |> assign(:active_monitor_count, active_monitor_count())
    |> assign(:signal_connected?, TradingOptionsSim.SignalConnection.connected?())
  end

  defp active_monitor_count do
    Registry.count(TradingOptionsSim.MonitorRegistry)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-2xl font-bold uppercase tracking-wide mb-6">System Performance</h1>

      <div class="flex flex-col gap-4">
        <.node_health_panel
          report={@report}
          active_monitor_count={@active_monitor_count}
          signal_connected?={@signal_connected?}
        />
        <.cron_health_panel workers={@cron_workers} pending_count={@pending_count} />
      </div>
    </Layouts.app>
    """
  end

  ## Node health

  attr :report, :map, required: true
  attr :active_monitor_count, :integer, required: true
  attr :signal_connected?, :boolean, required: true

  defp node_health_panel(assigns) do
    ~H"""
    <div class="border border-base-300">
      <div class="bg-base-300 px-4 py-3 border-b border-base-300 flex items-center gap-2">
        <.icon name="hero-server" class="h-4 w-4 text-primary" />
        <h2 class="font-data text-xs uppercase tracking-wider text-base-content/60">
          Node Health
        </h2>
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-px bg-base-300">
        <.stat_card
          title="Uptime"
          value={format_uptime(@report.uptime_seconds)}
          class={uptime_class(@report.uptime_seconds)}
        />
        <.stat_card
          title="Database"
          value={if db_up?(@report), do: "UP", else: "DOWN"}
          class={if db_up?(@report), do: "text-success", else: "text-error"}
        />
        <.stat_card
          title="Hub Connection"
          value={if hub_connected?(@report), do: "CONNECTED", else: "DISCONNECTED"}
          class={if hub_connected?(@report), do: "text-success", else: "text-error"}
        />
        <.stat_card
          title="Signal Connection"
          value={if @signal_connected?, do: "CONNECTED", else: "DISCONNECTED"}
          class={if @signal_connected?, do: "text-success", else: "text-error"}
        />
        <.stat_card title="Active Monitors" value={Integer.to_string(@active_monitor_count)} />
        <.stat_card title="Processes" value={"#{@report.process.count} / #{@report.process.limit}"} />
      </div>
    </div>
    """
  end

  defp db_up?(%{extra: %{db_pool: %{up?: up}}}), do: up
  defp db_up?(_report), do: false

  defp hub_connected?(%{extra: %{hub_connected: connected}}), do: connected
  defp hub_connected?(_report), do: false

  defp format_uptime(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_uptime(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m"

  defp format_uptime(seconds) do
    hours = div(seconds, 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    "#{hours}h #{minutes}m"
  end

  defp uptime_class(seconds) when seconds < @uptime_warning_seconds, do: "text-warning"
  defp uptime_class(_seconds), do: ""

  ## Cron / Oban health

  attr :workers, :list, required: true
  attr :pending_count, :integer, required: true

  defp cron_health_panel(assigns) do
    ~H"""
    <div class="border border-base-300">
      <div class="bg-base-300 px-4 py-3 border-b border-base-300 flex items-center gap-2">
        <.icon name="hero-clock" class="h-4 w-4 text-primary" />
        <h2 class="font-data text-xs uppercase tracking-wider text-base-content/60">
          Cron / Oban Health
        </h2>
        <span class="ml-auto font-data text-[11px] text-base-content/50">
          {@pending_count} pending job{if @pending_count == 1, do: "", else: "s"}
        </span>
      </div>

      <div class="overflow-x-auto">
        <table class="w-full font-data text-xs">
          <thead class="bg-base-300 uppercase tracking-wide text-[11px]">
            <tr>
              <th class="px-3 py-2 text-left">Worker</th>
              <th class="px-3 py-2 text-left">Last Run</th>
              <th class="px-3 py-2 text-left">State</th>
              <th class="px-3 py-2 text-left">Last Success</th>
              <th class="px-3 py-2 text-left">2nd-Last Success</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @workers} class="border-t border-base-300">
              <td class="px-3 py-2 text-base-content/80">{worker_short_name(row.worker)}</td>
              <td class="px-3 py-2 text-base-content/60">
                {format_job_time(row.last_job && row.last_job.inserted_at)}
              </td>
              <td class={["px-3 py-2", job_state_class(row.last_job)]}>
                {job_state_label(row.last_job)}
              </td>
              <td class="px-3 py-2 text-base-content/60">
                {format_job_time(row.last_success && row.last_success.completed_at)}
              </td>
              <td class="px-3 py-2 text-base-content/60">
                {format_job_time(row.second_last_success && row.second_last_success.completed_at)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp worker_short_name(worker), do: worker |> to_string() |> String.split(".") |> List.last()

  defp format_job_time(nil), do: "never"
  defp format_job_time(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp job_state_label(nil), do: "NEVER RAN"
  defp job_state_label(%{state: state}), do: String.upcase(state)

  defp job_state_class(nil), do: "text-warning"
  defp job_state_class(%{state: "completed"}), do: "text-success"
  defp job_state_class(%{state: state}) when state in ["discarded", "cancelled"], do: "text-error"
  defp job_state_class(_job), do: "text-base-content/60"
end
