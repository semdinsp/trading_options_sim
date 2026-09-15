defmodule TradingOptionsSimWeb.ActiveStrategiesLive do
  @moduledoc """
  Lists every `StrategyVersion` that currently has at least one open
  `SimRun`, with a symbol chip per open contract — this app's version
  of `trading_live`'s `StrategyMonitorLive` symbol-chip UI, scoped down
  to what this app can actually show today.

  A version's open runs are exactly the contracts with a live
  `ContractMonitor` running (see `Sim.list_active_strategy_versions/0`'s
  own doc) — chips here reflect the DB view of "currently active," not
  a live `Registry`/GenServer read (except the per-chip current price,
  which IS a live `ContractMonitor.snapshot/1` read, same source
  `StrategyVersionDetailLive`'s member cards use — see
  `attach_current_price/2`). `trading_live`'s chips also carry
  pending-order state, session-open/closed badges, and an
  expand-for-live-snapshot interaction; none of those have an equivalent
  here yet (no order lifecycle, no exchange-session tracking — see
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §9's known gaps), so this is a
  narrower v1: symbol + contract + direction + live price, polling
  rather than PubSub-driven (same reasoning as `RunsLive`'s own
  moduledoc).

  Each version card also has a Deactivate button (`SimActivator.deactivate/1`
  — same action `StrategyVersionsLive`'s own button performs), so an
  operator can stop a whole version's monitors directly from the page
  they're already watching it on rather than navigating away first.
  """

  use TradingOptionsSimWeb, :live_view

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.SimActivator

  @refresh_ms :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Active Strategies")
     |> load_active_versions()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, load_active_versions(socket)}
  end

  @impl true
  def handle_event("deactivate", %{"id" => id}, socket) do
    version = Sim.get_strategy_version!(id)
    {:ok, count} = SimActivator.deactivate(version)

    {:noreply,
     socket
     |> put_flash(:info, "Deactivated — #{count} monitor(s) stopped")
     |> load_active_versions()}
  end

  defp load_active_versions(socket) do
    active_versions =
      Sim.list_active_strategy_versions()
      |> Enum.map(fn version ->
        %{version | sim_runs: Enum.map(version.sim_runs, &attach_current_price(&1, version.id))}
      end)

    socket
    |> assign(:active_versions, active_versions)
    |> assign(:stage_counts, Sim.strategy_version_stage_counts())
  end

  # The chip's live current price — read fresh off the running
  # ContractMonitor (same source StrategyVersionDetailLive's own member
  # cards use) rather than anything stored on the SimRun itself, since
  # entry_price is fixed at entry and the DB is never updated tick by
  # tick. `nil` when the monitor isn't found (a race between an
  # already-committed open run and a monitor that has since stopped) or
  # hasn't been priced yet — the chip just omits the price in that case.
  defp attach_current_price(run, strategy_version_id) do
    contract_key = {run.symbol, run.expiry, run.strike, run.right}
    pid = ContractMonitor.whereis(strategy_version_id, contract_key)
    current_price = pid && fetch_current_price(pid)

    Map.put(run, :current_price, current_price)
  end

  defp fetch_current_price(pid) do
    Map.get(ContractMonitor.snapshot(pid).last_snapshot, "run_current_price")
  catch
    :exit, _reason -> nil
  end

  defp direction_chip_class("long"), do: "border-long/40 text-long"
  defp direction_chip_class("short"), do: "border-short/40 text-short"

  # Same formatting convention as StrategyVersionDetailLive's own
  # current_price_display/1 — kept as separate private helpers per
  # module (see that module's format_snapshot_value/1) rather than
  # shared, matching this app's existing per-LiveView-helper norm.
  defp format_current_price(nil), do: "—"
  defp format_current_price(%Decimal{} = price), do: "$#{Decimal.to_string(price)}"

  defp format_current_price(price) when is_float(price),
    do: "$#{:erlang.float_to_binary(price, decimals: 4)}"

  defp format_current_price(price), do: "$#{price}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center gap-4 mb-6">
        <h1 class="text-2xl font-bold uppercase tracking-wide">Active Strategies</h1>
        <.stage_counts_strip counts={@stage_counts} />
      </div>

      <div :if={@active_versions == []} class="border border-base-300 p-8 text-center">
        <p class="font-data text-sm uppercase tracking-wide text-base-content/40">
          No strategy versions currently have an open run
        </p>
      </div>

      <div :if={@active_versions != []} class="flex flex-col gap-px bg-base-300">
        <div :for={version <- @active_versions} class="bg-base-100 p-4">
          <div class="flex items-center gap-2 mb-3">
            <span class="signal-dot relative w-2 h-2 rounded-full bg-success"></span>
            <.link
              navigate={~p"/strategy_versions/#{version.id}"}
              class="font-bold uppercase tracking-wide hover:text-primary"
            >
              <h2 class="inline">
                {version.strategy.name} <span class="text-base-content/40">v{version.version}</span>
              </h2>
            </.link>
            <.lifecycle_badge stage={version.lifecycle_stage} />
            <span class="font-data text-xs text-base-content/40 ml-auto">
              {length(version.sim_runs)} open
            </span>
            <button
              type="button"
              phx-click="deactivate"
              phx-value-id={version.id}
              data-confirm="Deactivate this version? Any open position will be flattened and every running monitor stopped."
              class="px-1.5 py-0.5 border border-error/40 text-error bg-error/10 text-[11px] uppercase tracking-wide hover:bg-error/20"
            >
              Deactivate
            </button>
          </div>

          <div class="flex flex-wrap gap-2">
            <div
              :for={run <- version.sim_runs}
              class={[
                "inline-flex flex-col gap-0.5 px-1.5 py-1 border text-[11px] font-data uppercase tracking-wide",
                direction_chip_class(run.direction)
              ]}
            >
              <span>{run.symbol}</span>
              <span class="text-base-content/50 normal-case">
                {format_expiry(run.expiry)} {Decimal.to_string(run.strike)}{run.right}
              </span>
              <span class="normal-case tabular-nums">
                {format_current_price(run.current_price)}
              </span>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
