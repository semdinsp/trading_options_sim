defmodule TradingOptionsSimWeb.ActiveStrategiesLive do
  @moduledoc """
  Lists every `StrategyVersion` that currently has at least one open
  `SimRun`, with a symbol chip per open contract — this app's version
  of `trading_live`'s `StrategyMonitorLive` symbol-chip UI, scoped down
  to what this app can actually show today.

  A version's open runs are exactly the contracts with a live
  `ContractMonitor` running (see `Sim.list_active_strategy_versions/0`'s
  own doc) — chips here reflect the DB view of "currently active," not
  a live `Registry`/GenServer read. `trading_live`'s chips also carry
  pending-order state, session-open/closed badges, and an
  expand-for-live-snapshot interaction; none of those have an equivalent
  here yet (no order lifecycle, no exchange-session tracking — see
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §9's known gaps), so this is a
  narrower v1: symbol + contract + direction only, polling rather than
  PubSub-driven (same reasoning as `RunsLive`'s own moduledoc).
  """

  use TradingOptionsSimWeb, :live_view

  alias TradingOptionsSim.Sim

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

  defp load_active_versions(socket) do
    assign(socket, :active_versions, Sim.list_active_strategy_versions())
  end

  defp direction_chip_class("long"), do: "border-long/40 text-long"
  defp direction_chip_class("short"), do: "border-short/40 text-short"

  defp format_expiry(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>) do
    "#{y}-#{m}-#{d}"
  end

  defp format_expiry(other), do: other

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-2xl font-bold uppercase tracking-wide mb-6">Active Strategies</h1>

      <div :if={@active_versions == []} class="border border-base-300 p-8 text-center">
        <p class="font-data text-sm uppercase tracking-wide text-base-content/40">
          No strategy versions currently have an open run
        </p>
      </div>

      <div :if={@active_versions != []} class="flex flex-col gap-px bg-base-300">
        <div :for={version <- @active_versions} class="bg-base-100 p-4">
          <div class="flex items-center gap-2 mb-3">
            <span class="signal-dot relative w-2 h-2 rounded-full bg-success"></span>
            <h2 class="font-bold uppercase tracking-wide">
              {version.strategy.name} <span class="text-base-content/40">v{version.version}</span>
            </h2>
            <span class="px-1.5 py-0.5 border border-base-content/20 text-base-content/60 text-[11px] uppercase tracking-wide font-data">
              {version.lifecycle_stage}
            </span>
            <span class="font-data text-xs text-base-content/40 ml-auto">
              {length(version.sim_runs)} open
            </span>
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
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
