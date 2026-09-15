defmodule TradingOptionsSimWeb.ActiveStrategiesLive do
  @moduledoc """
  Lists every currently-active `StrategyVersion`, with one symbol chip
  per target-pool member — ported to match `trading_live`'s own
  `StrategyMonitorLive` chip design exactly (confirmed by reading that
  module directly), not just scoped-down as before.

  **One chip per target-pool member, not per open `SimRun`** — a member
  with no open position still gets a chip showing "Flat" (or "Last exit
  ..." if it has trade history), matching `trading_live`'s own layout.
  Confirmed live 2026-09-15 this distinction matters: the previous
  open-runs-only design left a `trading_hours_policy: "regular_hours_only"`
  version showing nothing at all outside market hours, which read as
  either "broken" or "still trading" depending on what an operator
  expected — a chip that's visibly present and says "Flat" removes that
  ambiguity.

  Chip coloring mirrors `trading_live`'s own `symbol_chip/1` precedence
  exactly, scoped down to what this app actually has (no pending-order
  or disabled-symbol concept):
    * Outer border/text color: green (`running?`) when a `ContractMonitor`
      is currently alive for this member's resolved contract, dim gray
      otherwise (monitor never started, or died/was killed) — **not**
      keyed on the exchange session being open or closed, same as
      `trading_live`.
    * The exchange session's own OPEN/CLOSED/UNMAPPED state is a
      separate, plain-text inline label next to the symbol (green/red/
      dim gray respectively) — computed the same way
      `ContractMonitor.session_open?/1` gates transmission, but read
      independently here purely for display.
    * "Flat" (dim gray) vs. "Position: Long/Short" (green/red by
      direction) vs. "Last exit $price ±pnl" (green/red/gray by realized
      P&L sign) — mutually exclusive per chip, same precedence
      `trading_live`'s own template uses.

  The bottom summary strip (`Realized`/`Net`/`Fills`/`W`/`L`) is
  `trading_live`'s own `performance_strip/1`, minus the Paper/Live
  prefix — this app has no live/paper distinction to label (see
  `Sim.today_stats_for_version/1`'s own doc for why "today," not
  cumulative).

  Each version card also has a Deactivate button
  (`SimActivator.deactivate/1` — same action `StrategyVersionsLive`'s
  own button performs).
  """

  use TradingOptionsSimWeb, :live_view

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.ExchangeSessionCache
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
        contract_template = SimActivator.resolve_contract_template(version.option_leg_config)

        members =
          version
          |> target_pool_members()
          |> Enum.map(&build_chip(version, contract_template, &1))
          |> Enum.sort_by(& &1.member.symbol)

        %{
          version: version,
          members: members,
          today_stats: Sim.today_stats_for_version(version)
        }
      end)

    socket
    |> assign(:active_versions, active_versions)
    |> assign(:stage_counts, Sim.strategy_version_stage_counts())
  end

  defp target_pool_members(%{target_pool_id: nil}), do: []

  defp target_pool_members(version) do
    version.target_pool_id |> Sim.get_target_pool!() |> Map.fetch!(:target_pool_members)
  end

  # Same "always derive from ONE live snapshot read" reasoning
  # StrategyVersionDetailLive's own build_member_entry/3 documents —
  # ported here rather than shared, matching this app's existing
  # per-LiveView-helper convention (see e.g. RunsLive/ActiveStrategiesLive's
  # own separate format_expiry/format_price copies before those were
  # promoted to CoreComponents; a session-wide review already tracked
  # further consolidation as a follow-up, not done piecemeal here).
  defp build_chip(version, contract_template, member) do
    pid =
      case contract_template do
        {:ok, template} ->
          contract_key = {member.symbol, template.expiry, template.strike, template.right}
          ContractMonitor.whereis(version.id, contract_key)

        {:error, :unsupported_leg_config} ->
          nil
      end

    snapshot = pid && fetch_snapshot(pid)

    run =
      if snapshot && snapshot.position_open? do
        version |> Sim.list_open_sim_runs() |> Enum.find(&(&1.symbol == member.symbol))
      end

    %{
      member: member,
      running?: not is_nil(snapshot),
      snapshot: snapshot,
      run: run,
      entry_fill: if(run, do: entry_fill(run)),
      fallback_direction: version.direction,
      last_closed_run: if(is_nil(run), do: Sim.last_closed_sim_run(version, member.symbol)),
      session_open?: session_open(member.exchange)
    }
  end

  defp entry_fill(run) do
    run |> Sim.list_sim_fills() |> Enum.find(&(&1.kind == "entry"))
  end

  defp fetch_snapshot(pid) do
    ContractMonitor.snapshot(pid)
  catch
    :exit, _reason -> nil
  end

  defp session_open(nil), do: nil

  defp session_open(exchange) do
    case ExchangeSessionCache.fetch(exchange) do
      nil -> nil
      session -> TradingCore.MarketHours.open?(session, DateTime.utc_now())
    end
  end

  defp chip_class(%{running?: true}), do: "border-success/40 text-success"
  defp chip_class(_chip), do: "border-base-content/15 text-base-content/40"

  defp session_class(true), do: "text-success"
  defp session_class(false), do: "text-error"
  defp session_class(nil), do: "text-base-content/30"

  defp session_label(true), do: "OPEN"
  defp session_label(false), do: "CLOSED"
  defp session_label(nil), do: "UNMAPPED"

  defp position_direction_class(nil, _direction), do: "text-base-content/30"
  defp position_direction_class(_run, "short"), do: "text-error/70"
  defp position_direction_class(_run, _direction), do: "text-success/70"

  defp pnl_class(nil), do: "text-base-content/60"

  defp pnl_class(pnl) do
    case Decimal.compare(pnl, Decimal.new(0)) do
      :gt -> "text-success"
      :lt -> "text-error"
      :eq -> "text-base-content/60"
    end
  end

  defp pnl_sign(pnl) do
    case Decimal.compare(pnl, Decimal.new(0)) do
      :lt -> "-"
      _ -> "+"
    end
  end

  defp format_price(nil), do: "—"
  defp format_price(%Decimal{} = price), do: "$#{Decimal.round(price, 2)}"

  defp format_qty(qty), do: to_string(qty)

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
          No strategy versions are currently active
        </p>
      </div>

      <div :if={@active_versions != []} class="flex flex-col gap-px bg-base-300">
        <div :for={entry <- @active_versions} class="bg-base-100 p-4">
          <div class="flex items-center gap-2 mb-3">
            <span class="signal-dot relative w-2 h-2 rounded-full bg-success"></span>
            <.link
              navigate={~p"/strategy_versions/#{entry.version.id}"}
              class="font-bold uppercase tracking-wide hover:text-primary"
            >
              <h2 class="inline">
                {entry.version.strategy.name}
                <span class="text-base-content/40">v{entry.version.version}</span>
              </h2>
            </.link>
            <.lifecycle_badge stage={entry.version.lifecycle_stage} />
            <span class="font-data text-xs text-base-content/40">
              {length(entry.members)} members
            </span>
            <button
              type="button"
              phx-click="deactivate"
              phx-value-id={entry.version.id}
              data-confirm="Deactivate this version? Any open position will be flattened and every running monitor stopped."
              class="px-1.5 py-0.5 border border-error/40 text-error bg-error/10 text-[11px] uppercase tracking-wide hover:bg-error/20"
            >
              Deactivate
            </button>
          </div>

          <div class="flex flex-wrap gap-2">
            <div
              :for={chip <- entry.members}
              class={[
                "inline-flex flex-col gap-0.5 px-1.5 py-1 border text-[11px] font-data uppercase tracking-wide",
                chip_class(chip)
              ]}
            >
              <div class="inline-flex items-center gap-1">
                <span>{chip.member.symbol}</span>
                <span class="text-base-content/40">{chip.member.exchange || "—"}</span>
                <span class={session_class(chip.session_open?)}>
                  {session_label(chip.session_open?)}
                </span>
              </div>

              <span
                :if={is_nil(chip.run)}
                class={[
                  "normal-case tracking-normal",
                  position_direction_class(nil, chip.fallback_direction)
                ]}
              >
                Flat
              </span>
              <span
                :if={chip.run}
                class={position_direction_class(chip.run, chip.run.direction)}
              >
                Position: {String.capitalize(chip.run.direction)}
              </span>
              <span :if={chip.run} class="text-base-content/50 normal-case tracking-normal">
                Entry {format_price(chip.run.entry_price)}
                <span :if={chip.entry_fill}>× {format_qty(chip.entry_fill.quantity)}</span>
              </span>

              <span
                :if={is_nil(chip.run) && chip.last_closed_run}
                class={["normal-case tracking-normal", pnl_class(chip.last_closed_run.realized_pnl)]}
              >
                Last exit {format_price(chip.last_closed_run.exit_price)} {pnl_sign(
                  chip.last_closed_run.realized_pnl || Decimal.new(0)
                )}{format_price(
                  chip.last_closed_run.realized_pnl && Decimal.abs(chip.last_closed_run.realized_pnl)
                )}
              </span>
            </div>
          </div>

          <div
            :if={entry.today_stats}
            class="mt-2 flex flex-wrap items-center gap-3 font-data text-[11px] uppercase tracking-wide text-base-content/60 border-t border-base-300 pt-2"
          >
            <span class={pnl_class(entry.today_stats.realized_pnl_gross)}>
              Realized {format_price(entry.today_stats.realized_pnl_gross)}
            </span>
            <span
              :if={entry.today_stats.realized_pnl_net}
              class={pnl_class(entry.today_stats.realized_pnl_net)}
            >
              Net {format_price(entry.today_stats.realized_pnl_net)}
            </span>
            <span>Fills {entry.today_stats.fill_count}</span>
            <span class="text-success">W {entry.today_stats.n_wins}</span>
            <span class="text-error">L {entry.today_stats.n_losses}</span>
          </div>
          <div
            :if={is_nil(entry.today_stats)}
            class="mt-2 font-data text-[11px] uppercase tracking-wide text-base-content/30 border-t border-base-300 pt-2"
          >
            No fills yet today
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
