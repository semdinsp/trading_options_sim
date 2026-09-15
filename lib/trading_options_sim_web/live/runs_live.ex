defmodule TradingOptionsSimWeb.RunsLive do
  @moduledoc """
  Lists every `SimRun` across every strategy version — open and closed,
  filterable by status. The operator-facing surface for "what has this
  app actually traded," complementing `ActiveStrategiesLive`'s
  "what's running right now" view.

  Polls on a timer rather than subscribing to a PubSub topic — no
  per-run or run-list broadcast exists yet (`ContractMonitor` only
  broadcasts on the underlying's own `"prices:SYMBOL"` topic it
  subscribes to, never publishes its own entry/exit events), so a fixed
  poll is the only way to catch a new fill without adding a new
  broadcast this task didn't ask for.
  """

  use TradingOptionsSimWeb, :live_view

  alias TradingOptionsSim.Sim

  @refresh_ms :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Runs")
     |> assign(:status_filter, nil)
     |> assign(:tagging_run_id, nil)
     |> load_runs()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status_filter =
      case params["status"] do
        s when s in ["open", "closed"] -> s
        _ -> nil
      end

    {:noreply, socket |> assign(:status_filter, status_filter) |> load_runs()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, load_runs(socket)}
  end

  @impl true
  def handle_event("toggle_tag_control", %{"id" => id}, socket) do
    next_id = if socket.assigns.tagging_run_id == id, do: nil, else: id
    {:noreply, assign(socket, :tagging_run_id, next_id)}
  end

  def handle_event("add_tag", %{"run_id" => run_id, "tag_name" => tag_name}, socket) do
    trimmed = String.trim(tag_name)

    if trimmed == "" do
      {:noreply, socket}
    else
      run = Sim.get_sim_run!(run_id)
      {:ok, _run} = Sim.add_tag_to_run_by_name(run, trimmed)
      {:noreply, load_runs(socket)}
    end
  end

  def handle_event("remove_tag", %{"id" => id, "tag_id" => tag_id}, socket) do
    run = Sim.get_sim_run!(id)
    remaining_ids = run.tags |> Enum.reject(&(&1.id == tag_id)) |> Enum.map(& &1.id)
    {:ok, _run} = Sim.put_run_tags(run, remaining_ids)
    {:noreply, load_runs(socket)}
  end

  defp load_runs(socket) do
    assign(socket, :runs, Sim.list_sim_runs(socket.assigns.status_filter))
  end

  defp status_badge_class("open"), do: "border-info/40 text-info bg-info/10"
  defp status_badge_class("closed"), do: "border-base-content/20 text-base-content/60"
  defp status_badge_class(_), do: "border-base-content/20 text-base-content/60"

  defp direction_class("long"), do: "text-long"
  defp direction_class("short"), do: "text-short"

  defp pnl_class(nil), do: "text-base-content/40"

  defp pnl_class(pnl) do
    case Decimal.compare(pnl, Decimal.new(0)) do
      :lt -> "text-error"
      _ -> "text-success"
    end
  end

  # "$"-prefixed, matching the price formatting convention used
  # throughout StrategyVersionDetailLive (e.g. its entry/exit/last-closed
  # price displays) rather than a bare, ambiguous number.
  defp format_price(nil), do: "—"
  defp format_price(%Decimal{} = price), do: "$#{Decimal.round(price, 2)}"

  defp contract_label(run) do
    "#{run.symbol} #{format_expiry(run.expiry)} #{Decimal.to_string(run.strike)}#{run.right}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold uppercase tracking-wide">Runs</h1>

        <div class="flex gap-1">
          <.link patch={~p"/runs"} class={filter_link_class(@status_filter, nil)}>All</.link>
          <.link patch={~p"/runs?status=open"} class={filter_link_class(@status_filter, "open")}>
            Open
          </.link>
          <.link patch={~p"/runs?status=closed"} class={filter_link_class(@status_filter, "closed")}>
            Closed
          </.link>
        </div>
      </div>

      <div :if={@runs == []} class="border border-base-300 p-8 text-center">
        <p class="font-data text-sm uppercase tracking-wide text-base-content/40">
          No runs to show
        </p>
      </div>

      <div :if={@runs != []} class="border border-base-300 overflow-x-auto">
        <table class="table font-data text-xs">
          <thead class="bg-base-300 uppercase tracking-wide text-[11px]">
            <tr>
              <th>Strategy</th>
              <th>Contract</th>
              <th>Direction</th>
              <th>Status</th>
              <th>Entry</th>
              <th>Exit</th>
              <th>Realized P&amp;L</th>
              <th>Exit reason</th>
              <th>Tags</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={run <- @runs} class="border-t border-base-300">
              <td>
                {run.strategy_version.strategy.name}
                <span class="text-base-content/40">v{run.strategy_version.version}</span>
              </td>
              <td>{contract_label(run)}</td>
              <td class={["uppercase", direction_class(run.direction)]}>{run.direction}</td>
              <td>
                <span class={[
                  "inline-block px-1.5 py-0.5 border text-[11px] uppercase tracking-wide",
                  status_badge_class(run.status)
                ]}>
                  {run.status}
                </span>
              </td>
              <td>{format_price(run.entry_price)}</td>
              <td>{format_price(run.exit_price)}</td>
              <td class={pnl_class(run.realized_pnl)}>
                {format_price(run.realized_pnl)}
              </td>
              <td class="text-base-content/60">{run.exit_reason || "—"}</td>
              <td>
                <div class="flex flex-wrap items-center gap-1.5">
                  <span
                    :for={tag <- run.tags}
                    class="inline-flex items-center gap-1 px-1.5 py-0.5 border border-secondary/40 text-secondary bg-secondary/10 text-[11px] uppercase tracking-wide"
                  >
                    {tag.name}
                    <button
                      type="button"
                      phx-click="remove_tag"
                      phx-value-id={run.id}
                      phx-value-tag_id={tag.id}
                      class="hover:text-error"
                    >
                      <.icon name="hero-x-mark" class="h-3 w-3" />
                    </button>
                  </span>

                  <button
                    type="button"
                    phx-click="toggle_tag_control"
                    phx-value-id={run.id}
                    class="text-base-content/40 hover:text-primary"
                    title="Manage tags"
                    aria-label="Manage tags"
                  >
                    <.icon name="hero-tag" class="h-4 w-4" />
                  </button>

                  <form :if={@tagging_run_id == run.id} phx-submit="add_tag" class="inline-flex">
                    <input type="hidden" name="run_id" value={run.id} />
                    <label for={"add-tag-input-#{run.id}"} class="sr-only">Add tag</label>
                    <input
                      type="text"
                      id={"add-tag-input-#{run.id}"}
                      name="tag_name"
                      placeholder="add tag…"
                      class="input input-xs input-bordered font-data text-[11px]"
                      autofocus
                    />
                  </form>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
