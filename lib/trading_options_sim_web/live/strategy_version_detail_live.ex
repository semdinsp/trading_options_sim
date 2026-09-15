defmodule TradingOptionsSimWeb.StrategyVersionDetailLive do
  @moduledoc """
  Per-strategy-version detail page — reached by clicking a version's
  name on `ActiveStrategiesLive` or `StrategyVersionsLive`. Shows the
  entry/exit rule JSON, position sizing, tags (with inline add/remove),
  notes, and one row per target-pool member with its resolved contract
  (if a `SimRun` exists), live signal values, and position/last-fill
  status — this app's counterpart to `trading_live`'s
  `StrategyDetailLive`.

  Deliberately narrower than that page in a few ways specific to this
  app's architecture, not an oversight:

    * No IBKR reconcile / portfolio-risk-guardian sections — this is a
      simulator with no real broker positions to reconcile against and
      no cross-strategy risk system.
    * No stop-loss/take-profit exit-levels table — `SimRun` carries
      `stop_loss_price`/`take_profit_price` fields, but nothing in this
      app currently computes or writes them (there's no
      `risk_controls`-style config); exit is purely rule-driven via
      `entry_rule`/`exit_rule` JSON evaluated by `TradingCore.RuleEngine`,
      shown as-is rather than fabricating a levels table with no real
      data behind it.
    * One row per target-pool member (underlying), not per `SimRun` —
      a target pool member is always an underlying; the specific option
      contract for it is resolved at activation time (see
      `SimActivator.start_for_member/3`), so this matches
      `trading_live`'s own per-symbol layout with the resolved contract
      shown inline when a run exists for it.
    * No per-signal-key "last updated" timestamp — `ContractMonitor`
      doesn't track one (see its own `snapshot/1`), so only the current
      value is shown.

  Polls at `@refresh_ms` while mounted, same "only while this page is
  open" scoping `trading_live`'s own detail page documents — the list
  pages' own slower polls are unaffected.
  """

  use TradingOptionsSimWeb, :live_view

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.SimActivator

  @refresh_ms :timer.seconds(2)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    {:ok,
     socket
     |> assign(:editing_notes?, false)
     |> assign(:all_tags, Sim.list_tags())
     |> load_version(id)}
  end

  @impl true
  def handle_info(:refresh, %{assigns: %{editing_notes?: true}} = socket) do
    {:noreply, load_version(socket, socket.assigns.version.id)}
  end

  def handle_info(:refresh, socket) do
    {:noreply, load_version(socket, socket.assigns.version.id)}
  end

  @impl true
  def handle_event("activate", _params, socket) do
    socket =
      case SimActivator.activate(socket.assigns.version) do
        {:ok, pids, []} ->
          put_flash(socket, :info, "Activated — #{length(pids)} monitor(s) running")

        {:ok, pids, unsubscribed_symbols} ->
          put_flash(
            socket,
            :error,
            "Activated — #{length(pids)} monitor(s) running, but live data subscription failed for #{Enum.join(unsubscribed_symbols, ", ")} — check trading_hub connectivity"
          )

        {:error, :no_target_pool} ->
          put_flash(socket, :error, "Can't activate — this version has no target pool set")

        {:error, :unsupported_leg_config} ->
          put_flash(
            socket,
            :error,
            "Can't activate — option_leg_config isn't a supported fixed_strike/fixed selection"
          )
      end

    {:noreply, load_version(socket, socket.assigns.version.id)}
  end

  def handle_event("deactivate", _params, socket) do
    {:ok, count} = SimActivator.deactivate(socket.assigns.version)

    {:noreply,
     socket
     |> put_flash(:info, "Deactivated — #{count} monitor(s) stopped")
     |> load_version(socket.assigns.version.id)}
  end

  def handle_event("retire", _params, socket) do
    socket =
      case Sim.downgrade_strategy_version(socket.assigns.version, "retired") do
        {:ok, _retired} -> put_flash(socket, :info, "Retired")
        {:error, _reason} -> put_flash(socket, :error, "Could not retire this version")
      end

    {:noreply, load_version(socket, socket.assigns.version.id)}
  end

  def handle_event("unretire", _params, socket) do
    socket =
      case Sim.promote_strategy_version(socket.assigns.version, "discovery") do
        {:ok, _unretired} -> put_flash(socket, :info, "Unretired — back to discovery")
        {:error, _reason} -> put_flash(socket, :error, "Could not unretire this version")
      end

    {:noreply, load_version(socket, socket.assigns.version.id)}
  end

  def handle_event("edit_notes", _params, socket) do
    {:noreply, assign(socket, :editing_notes?, true)}
  end

  def handle_event("cancel_notes", _params, socket) do
    {:noreply, assign(socket, :editing_notes?, false)}
  end

  def handle_event("save_notes", %{"notes" => notes}, socket) do
    case Sim.set_strategy_version_notes(socket.assigns.version, blank_to_nil(notes)) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> assign(:editing_notes?, false)
         |> put_flash(:info, "Notes saved")
         |> load_version(socket.assigns.version.id)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save notes")}
    end
  end

  def handle_event("add_tag", %{"tag_name" => tag_name}, socket) do
    case String.trim(tag_name) do
      "" ->
        {:noreply, socket}

      trimmed ->
        case Sim.add_tag_to_strategy_version_by_name(socket.assigns.version, trimmed) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> assign(:all_tags, Sim.list_tags())
             |> load_version(socket.assigns.version.id)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not add tag")}
        end
    end
  end

  def handle_event("remove_tag", %{"tag_id" => tag_id}, socket) do
    case Sim.remove_tag_from_strategy_version(socket.assigns.version, tag_id) do
      {:ok, _updated} -> {:noreply, load_version(socket, socket.assigns.version.id)}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "Could not remove tag")}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp load_version(socket, id) do
    version = Sim.get_strategy_version_detail!(id)
    contract_template = SimActivator.resolve_contract_template(version.option_leg_config)

    members =
      version.target_pool
      |> case do
        nil -> []
        pool -> pool.target_pool_members
      end
      |> Enum.map(&build_member_entry(version, contract_template, &1))
      |> Enum.sort_by(& &1.member.symbol)

    is_active? = not is_nil(version.activated_at) and is_nil(version.deactivated_at)

    socket
    |> assign(:version, version)
    |> assign(:members, members)
    |> assign(:is_active?, is_active?)
    |> assign(:recent_fills, Sim.list_recent_fills_for_version(version))
  end

  # Always derives this member's state from ONE live read
  # (ContractMonitor.snapshot/1) rather than trusting a `SimRun` fetched
  # earlier in `load_version/2` — `whereis/2` is keyed by
  # `{strategy_version_id, contract_key}` (see ContractMonitor's own
  # doc on why), so a still-alive, still-watching monitor for this
  # member's resolved contract stays discoverable whether or not it
  # currently has an open run, and its own `position_open?` is the
  # single source of truth for whether a run should exist right now.
  #
  # Confirmed live 2026-09-15: an earlier version of this function took
  # `run` as a pre-fetched, separately-queried argument (from a
  # `list_open_sim_runs/1` call made before this one ran) — a version
  # whose entry/exit rules sit close together on an oscillating signal
  # can flip position_open? several times across a handful of 2-second
  # poll cycles, and a stale `run` fetched on an earlier cycle stayed
  # attached to a `nil`-run "Position open — details refreshing…"
  # placeholder for multiple cycles rather than resolving on the very
  # next one. Fetching the run fresh, only when the monitor's own
  # snapshot says a position is actually open, keeps both reads from
  # ever describing two different points in time.
  defp build_member_entry(version, contract_template, member) do
    pid =
      case contract_template do
        {:ok, template} ->
          contract_key = {member.symbol, template.expiry, template.strike, template.right}
          ContractMonitor.whereis(version.id, contract_key)

        {:error, :unsupported_leg_config} ->
          nil
      end

    snapshot = pid && fetch_monitor_snapshot(pid)

    run =
      if snapshot && snapshot.position_open? do
        version |> Sim.list_open_sim_runs() |> Enum.find(&(&1.symbol == member.symbol))
      end

    entry_fill = if run, do: entry_fill(run)

    %{
      member: member,
      run: run,
      running?: not is_nil(snapshot),
      snapshot: snapshot,
      entry_fill: entry_fill,
      last_closed_run: if(is_nil(run), do: Sim.last_closed_sim_run(version, member.symbol)),
      fallback_direction: version.direction
    }
  end

  defp entry_fill(run) do
    run |> Sim.list_sim_fills() |> Enum.find(&(&1.kind == "entry"))
  end

  defp fetch_monitor_snapshot(pid) do
    ContractMonitor.snapshot(pid)
  catch
    :exit, _reason -> nil
  end

  defp format_qty(%Decimal{} = qty), do: qty |> Decimal.normalize() |> Decimal.to_string(:normal)
  defp format_qty(qty) when is_binary(qty), do: qty
  defp format_qty(qty), do: to_string(qty)

  defp qty_display(sizing) do
    case Map.get(sizing || %{}, "qty") do
      nil -> nil
      %Decimal{} = qty -> Decimal.to_string(Decimal.normalize(qty), :normal)
      qty -> to_string(qty)
    end
  end

  defp format_position_sizing(nil), do: "(not set)"

  defp format_position_sizing(sizing) when map_size(sizing) == 0,
    do: "(no config captured — entries will be skipped until position_sizing is set)"

  defp format_position_sizing(sizing), do: Jason.encode!(sizing, pretty: true)

  defp format_rule(nil), do: "(not set — vacuously true)"
  defp format_rule(rule) when map_size(rule) == 0, do: "(empty — vacuously true)"
  defp format_rule(rule), do: Jason.encode!(rule, pretty: true)

  defp format_expiry(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>) do
    "#{y}-#{m}-#{d}"
  end

  defp format_expiry(other), do: other

  defp format_snapshot_value(%Decimal{} = value), do: Decimal.to_string(value)

  defp format_snapshot_value(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 4)

  defp format_snapshot_value(nil), do: "—"
  defp format_snapshot_value(value), do: to_string(value)

  # "Current" price fallback shown while a position is open but its own
  # SimRun hasn't resolved yet — reads straight from the monitor's own
  # in-memory last_snapshot (always instantly available, no DB
  # round-trip needed) rather than leaving the operator with no price
  # at all during a real, briefly-open position on a fast-oscillating
  # signal (confirmed live 2026-09-15).
  defp current_price_display(snapshot) do
    case Map.get(snapshot.last_snapshot, "run_current_price") do
      nil -> "—"
      price -> "$#{format_snapshot_value(price)}"
    end
  end

  defp direction_class("long"), do: "border-long/40 text-long"
  defp direction_class("short"), do: "border-short/40 text-short"
  defp direction_class(_other), do: "border-base-content/20 text-base-content/60"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center gap-3 border-b border-base-300 pb-3 mb-4 flex-wrap">
        <.link
          navigate={~p"/strategy_versions"}
          class="p-1 border border-base-content/15 text-base-content/50 hover:border-primary/40 hover:text-primary"
          aria-label="Back to strategy versions"
        >
          <.icon name="hero-arrow-left" class="h-4 w-4" />
        </.link>

        <h1 class="text-xl font-bold uppercase tracking-wide">
          {@version.strategy.name} <span class="text-base-content/40">v{@version.version}</span>
        </h1>

        <.lifecycle_badge stage={@version.lifecycle_stage} />

        <span
          :if={@is_active?}
          class="inline-flex items-center gap-1 px-1.5 py-0.5 border border-success/40 text-success bg-success/10 text-[11px] uppercase tracking-wide font-data"
        >
          <span class="signal-dot relative w-1.5 h-1.5 rounded-full bg-success"></span> Active
        </span>

        <span class={[
          "px-1.5 py-0.5 border text-[11px] uppercase tracking-wide font-data",
          direction_class(@version.direction)
        ]}>
          {@version.direction}
        </span>

        <span class="font-data text-xs text-base-content/40" title={@version.id}>
          {@version.id}
        </span>
        <.copy_uuid_button id="copy-version-id" value={@version.id} title="Copy version ID" />

        <button
          :if={not @is_active?}
          type="button"
          class="px-2 py-1 border border-success/40 text-success bg-success/10 text-[11px] font-data uppercase tracking-wide hover:bg-success/20"
          phx-click="activate"
        >
          Activate
        </button>
        <button
          :if={@is_active?}
          type="button"
          class="px-2 py-1 border border-error/40 text-error bg-error/10 text-[11px] font-data uppercase tracking-wide hover:bg-error/20"
          phx-click="deactivate"
          data-confirm="Deactivate this version? Any open position will be flattened and every running monitor stopped."
        >
          Deactivate
        </button>

        <.retire_button
          stage={@version.lifecycle_stage}
          version_id={@version.id}
          class="px-2 py-1 text-[11px]"
        />
      </div>

      <div class="flex-1 overflow-y-auto flex flex-col gap-3">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
          <div class="border border-warning/40 bg-base-100 p-3">
            <div class="font-data text-[11px] uppercase tracking-wider text-base-content/50 mb-1">
              Entry Rule
            </div>
            <pre class="font-data text-[11px] bg-base-200 border border-base-300 p-2 overflow-x-auto whitespace-pre-wrap">{format_rule(Map.get(@version.rules, "entry"))}</pre>
          </div>

          <div class="border border-warning/40 bg-base-100 p-3">
            <div class="font-data text-[11px] uppercase tracking-wider text-base-content/50 mb-1">
              Exit Rule
            </div>
            <pre class="font-data text-[11px] bg-base-200 border border-base-300 p-2 overflow-x-auto whitespace-pre-wrap">{format_rule(Map.get(@version.rules, "exit"))}</pre>
          </div>
        </div>

        <div class="border border-warning/40 bg-base-100 p-3">
          <div class="font-data text-[11px] uppercase tracking-wider text-base-content/50 mb-1">
            Position Sizing
          </div>

          <div class="mb-2 font-data text-[11px]">
            <span class="text-base-content/50 uppercase tracking-wide">Method</span>
            <span class="ml-2">{Map.get(@version.position_sizing || %{}, "method") || "—"}</span>
            <span
              :if={qty_display(@version.position_sizing)}
              class="ml-2 text-base-content/50 uppercase tracking-wide"
            >
              Qty
            </span>
            <span :if={qty_display(@version.position_sizing)} class="ml-2 tabular-nums">
              {qty_display(@version.position_sizing)}
            </span>
          </div>

          <div class="font-data text-[11px] uppercase tracking-wider text-base-content/50 mb-1">
            Raw Config
          </div>
          <pre class="font-data text-[11px] bg-base-200 border border-base-300 p-2 overflow-x-auto whitespace-pre-wrap">{format_position_sizing(@version.position_sizing)}</pre>
        </div>

        <div class="border border-warning/40 bg-base-100 p-3">
          <div class="font-data text-[11px] uppercase tracking-wider text-base-content/50 mb-2">
            <.icon name="hero-tag" class="h-4 w-4 mr-1 inline text-primary" /> Tags
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <span
              :for={tag <- @version.tags}
              class="inline-flex items-center gap-1 px-2 py-0.5 border border-secondary/40 bg-secondary/10 text-secondary text-xs"
            >
              {tag.name}
              <button
                type="button"
                phx-click="remove_tag"
                phx-value-tag_id={tag.id}
                title={"Remove #{tag.name}"}
                class="hover:text-error"
              >
                <.icon name="hero-x-mark" class="h-3 w-3" />
              </button>
            </span>

            <form phx-submit="add_tag" class="inline-flex items-center gap-1">
              <label for="add-tag-input" class="sr-only">Add tag</label>
              <input
                type="text"
                id="add-tag-input"
                name="tag_name"
                placeholder="Add tag…"
                autocomplete="off"
                class="input input-xs w-28 font-sans text-xs"
              />
              <button
                type="submit"
                aria-label="Add tag"
                class="px-1.5 py-0.5 border border-base-content/15 text-base-content/50 hover:border-primary/40 hover:text-primary"
              >
                <.icon name="hero-plus" class="h-3 w-3" />
              </button>
            </form>
          </div>
        </div>

        <div
          :if={@version.notes || @editing_notes?}
          class="border border-warning/40 bg-base-100 p-3"
        >
          <div :if={not @editing_notes?}>
            <div class="font-data text-[11px] uppercase tracking-wider text-base-content/50 mb-2 flex items-center justify-between">
              <span>
                <.icon name="hero-document-text" class="h-4 w-4 mr-1 inline text-primary" /> Notes
              </span>
              <button
                type="button"
                phx-click="edit_notes"
                class="normal-case tracking-normal px-1.5 py-0.5 border border-base-content/15 text-base-content/50 hover:border-primary/40 hover:text-primary"
              >
                <.icon name="hero-pencil" class="h-3 w-3 mr-1 inline" /> Edit
              </button>
            </div>
            <p class="text-sm text-base-content/80 whitespace-pre-wrap">{@version.notes}</p>
          </div>

          <form :if={@editing_notes?} phx-submit="save_notes" class="flex flex-col gap-3">
            <div class="flex items-center justify-between">
              <div
                id="notes-field-label"
                class="font-data text-[11px] uppercase tracking-wider text-base-content/50"
              >
                <.icon name="hero-document-text" class="h-4 w-4 mr-1 inline text-primary" /> Notes
              </div>
              <div class="flex items-center gap-2">
                <button
                  type="button"
                  phx-click="cancel_notes"
                  class="px-2 py-1 border border-base-content/15 text-[11px] font-data uppercase tracking-wide text-base-content/50 hover:border-base-content/30"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  class="px-2 py-1 border border-primary/50 text-primary bg-primary/10 text-[11px] font-data uppercase tracking-wide hover:bg-primary/20"
                >
                  Save
                </button>
              </div>
            </div>
            <textarea
              name="notes"
              rows="3"
              aria-labelledby="notes-field-label"
              class="textarea textarea-sm w-full font-sans text-sm"
              placeholder="Why this strategy exists, at a glance…"
            >{@version.notes}</textarea>
          </form>
        </div>

        <button
          :if={not @editing_notes? and is_nil(@version.notes)}
          type="button"
          phx-click="edit_notes"
          class="self-start px-2 py-1 border border-base-content/15 text-[11px] font-data uppercase tracking-wide text-base-content/50 hover:border-primary/40 hover:text-primary"
        >
          <.icon name="hero-plus" class="h-3.5 w-3.5 mr-1 inline" /> Add Notes
        </button>

        <div :if={@version.target_pool == nil} class="border border-base-300 p-8 text-center">
          <p class="font-data text-sm uppercase tracking-wide text-base-content/40">
            No target pool set — activation is unavailable until one is chosen
          </p>
        </div>

        <.member_card :for={entry <- @members} entry={entry} />

        <.recent_fills_panel fills={@recent_fills} />
      </div>
    </Layouts.app>
    """
  end

  attr :fills, :list, required: true

  # Every entry/exit fill across every target-pool member's contract,
  # most-recent-first — a direct answer to "did a position actually
  # open/close, and what did it fill at," independent of whichever
  # member card the operator happens to be looking at (a fill for a
  # symbol whose card has since gone quiet is still visible here).
  # Hidden entirely when empty rather than showing an empty panel on
  # every version that's never had a fill yet.
  defp recent_fills_panel(assigns) do
    ~H"""
    <div :if={@fills != []} class="border border-warning/40 bg-base-100 p-3">
      <div class="font-data text-[11px] uppercase tracking-wider text-base-content/50 mb-2">
        Recent Fills
      </div>
      <div class="overflow-x-auto">
        <table class="font-data text-[11px] w-full">
          <thead>
            <tr class="text-base-content/40 uppercase tracking-wide text-left">
              <th class="pr-3 py-0.5">Symbol</th>
              <th class="pr-3 py-0.5">Contract</th>
              <th class="pr-3 py-0.5">Kind</th>
              <th class="pr-3 py-0.5">Action</th>
              <th class="pr-3 py-0.5 text-right">Qty</th>
              <th class="pr-3 py-0.5 text-right">Price</th>
              <th class="pr-3 py-0.5">Filled</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={fill <- @fills} class="text-base-content/80 border-t border-base-300/50">
              <td class="pr-3 py-0.5 font-bold">{fill.sim_run.symbol}</td>
              <td class="pr-3 py-0.5 text-base-content/60">
                {format_expiry(fill.sim_run.expiry)} {Decimal.to_string(fill.sim_run.strike)}{fill.sim_run.right}
              </td>
              <td class="pr-3 py-0.5 uppercase">{fill.kind}</td>
              <td class="pr-3 py-0.5 uppercase">{fill.action}</td>
              <td class="pr-3 py-0.5 text-right tabular-nums">{fill.quantity}</td>
              <td class="pr-3 py-0.5 text-right tabular-nums">
                ${Decimal.round(fill.fill_price, 2)}
              </td>
              <td class="pr-3 py-0.5 text-base-content/50">{fill.filled_at}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :entry, :map, required: true

  defp member_card(assigns) do
    ~H"""
    <div class={[
      "border p-3 bg-base-100",
      cond do
        @entry.running? && @entry.snapshot.ibkr_live_subscribed? == false -> "border-error/60"
        @entry.running? -> "border-success/40"
        true -> "border-base-300"
      end
    ]}>
      <div class="flex items-center justify-between gap-4 flex-wrap mb-2">
        <div class="flex items-center gap-2">
          <span class="font-bold text-lg font-data">{@entry.member.symbol}</span>
          <span class="text-base-content/40 text-sm">{@entry.member.exchange || "—"}</span>

          <span :if={@entry.run} class="font-data text-[11px] text-base-content/50">
            {format_expiry(@entry.run.expiry)} {Decimal.to_string(@entry.run.strike)}{@entry.run.right}
          </span>

          <span class={[
            "px-1.5 py-0.5 border text-[11px] uppercase tracking-wide font-data",
            if(@entry.running?,
              do: "border-success/40 text-success",
              else: "border-base-content/20 text-base-content/40"
            )
          ]}>
            {if @entry.running?, do: "Running", else: "Not running"}
          </span>

          <span
            :if={@entry.running? && @entry.snapshot.ibkr_live_subscribed? == false}
            class="px-1.5 py-0.5 border border-error/60 text-error bg-error/10 text-[11px] uppercase tracking-wide font-data animate-pulse"
            title="This monitor's real trading_hub subscribe request failed at startup — it is running and evaluating on whatever stale/empty data it already has, not receiving new live ticks."
          >
            No market data
          </span>
        </div>
      </div>

      <div :if={@entry.running?} class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div>
          <div class="font-data text-[11px] uppercase tracking-wider text-base-content/50 mb-1">
            Live signal values
          </div>

          <div :if={map_size(@entry.snapshot.last_snapshot) == 0} class="text-base-content/30 text-sm">
            No signal/tick values received yet
          </div>

          <table
            :if={map_size(@entry.snapshot.last_snapshot) > 0}
            class="font-data text-[11px] w-full"
          >
            <tbody>
              <tr :for={{key, value} <- Enum.sort(@entry.snapshot.last_snapshot)}>
                <td class="text-base-content/40 pr-3 py-0.5">{key}</td>
                <td class="pr-3 py-0.5 tabular-nums">{format_snapshot_value(value)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div>
          <div class="font-data text-[11px] uppercase tracking-wider text-base-content/50 mb-1">
            Position
          </div>

          <div :if={not @entry.snapshot.position_open?} class="text-base-content/30 text-sm">
            Flat — no open position
          </div>

          <table :if={@entry.snapshot.position_open?} class="font-data text-[11px] w-full">
            <tbody>
              <tr>
                <td class="text-base-content/40 pr-3 py-0.5">Direction</td>
                <td class={[
                  "pr-3 py-0.5 uppercase",
                  direction_class((@entry.run && @entry.run.direction) || @entry.fallback_direction)
                ]}>
                  {(@entry.run && @entry.run.direction) || @entry.fallback_direction}
                </td>
              </tr>
              <tr :if={@entry.run}>
                <td class="text-base-content/40 pr-3 py-0.5">Entry</td>
                <td class="pr-3 py-0.5 tabular-nums">
                  ${Decimal.round(@entry.run.entry_price, 2)}
                  <span :if={@entry.entry_fill}>× {format_qty(@entry.entry_fill.quantity)}</span>
                </td>
              </tr>
              <tr :if={@entry.entry_fill}>
                <td class="text-base-content/40 pr-3 py-0.5">Entered</td>
                <td class="pr-3 py-0.5">{@entry.entry_fill.filled_at}</td>
              </tr>
              <tr :if={is_nil(@entry.run)}>
                <td class="text-base-content/40 pr-3 py-0.5">Current</td>
                <td class="pr-3 py-0.5 tabular-nums">
                  {current_price_display(@entry.snapshot)}
                </td>
              </tr>
              <tr :if={is_nil(@entry.run)}>
                <td class="text-base-content/40 pr-3 py-0.5" colspan="2">
                  <span class="text-base-content/30 normal-case">
                    Entry price/qty pending — this contract's own
                    <span class="font-data">SimRun</span>
                    hasn't loaded yet (a real position, briefly open on a fast-oscillating signal).
                  </span>
                </td>
              </tr>
            </tbody>
          </table>

          <div
            :if={not @entry.snapshot.position_open? and @entry.last_closed_run}
            class="mt-2 font-data text-[11px]"
          >
            <span class="text-base-content/40">Last closed:</span>
            <span :if={@entry.last_closed_run.exit_price}>
              ${Decimal.round(@entry.last_closed_run.exit_price, 2)}
            </span>
            <span
              :if={@entry.last_closed_run.realized_pnl}
              class={pnl_class(@entry.last_closed_run.realized_pnl)}
            >
              {pnl_sign(@entry.last_closed_run.realized_pnl)}${Decimal.round(
                Decimal.abs(@entry.last_closed_run.realized_pnl),
                2
              )}
            </span>
            <span :if={is_nil(@entry.last_closed_run.exit_price)} class="text-base-content/50">
              Closed without an entry ({@entry.last_closed_run.exit_reason})
            </span>
          </div>
        </div>
      </div>

      <div
        :if={not @entry.running? and @entry.last_closed_run}
        class="font-data text-[11px]"
      >
        <span class="text-base-content/40">Last closed:</span>
        <span :if={@entry.last_closed_run.exit_price}>
          ${Decimal.round(@entry.last_closed_run.exit_price, 2)}
        </span>
        <span
          :if={@entry.last_closed_run.realized_pnl}
          class={pnl_class(@entry.last_closed_run.realized_pnl)}
        >
          {pnl_sign(@entry.last_closed_run.realized_pnl)}${Decimal.round(
            Decimal.abs(@entry.last_closed_run.realized_pnl),
            2
          )}
        </span>
        <span :if={is_nil(@entry.last_closed_run.exit_price)} class="text-base-content/50">
          Closed without an entry ({@entry.last_closed_run.exit_reason})
        </span>
      </div>

      <div
        :if={not @entry.running? and is_nil(@entry.last_closed_run)}
        class="text-base-content/30 text-sm"
      >
        No monitor running for this symbol — activate the strategy above.
      </div>
    </div>
    """
  end

  defp pnl_sign(pnl) do
    case Decimal.compare(pnl, Decimal.new(0)) do
      :lt -> "-"
      _ -> "+"
    end
  end

  defp pnl_class(pnl) do
    case Decimal.compare(pnl, Decimal.new(0)) do
      :lt -> "text-error"
      :gt -> "text-success"
      :eq -> "text-base-content/60"
    end
  end
end
