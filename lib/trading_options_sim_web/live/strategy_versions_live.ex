defmodule TradingOptionsSimWeb.StrategyVersionsLive do
  @moduledoc """
  Every `StrategyVersion` across every strategy, filterable by
  `lifecycle_stage` — the one list that also serves as the
  retired-strategies view (a `?stage=retired` filter, not a separate
  screen — `Sim.list_strategy_versions/1` already covers every stage
  through one query). Each row shows its tag chips and an inline
  add/remove tag control, per `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §3a —
  and an Activate/Deactivate button (`SimActivator.activate/1` /
  `.deactivate/1`), independent of `lifecycle_stage`: "activated" means
  "has running monitors," not a stage transition, so a version can be
  (de)activated at any stage, including `retired` (deactivating a
  version nobody got around to before retiring it is still a real,
  useful action; re-activating a retired one is intentionally still
  allowed here even though `Sim.promote_strategy_version/2` wouldn't
  let a retired version move to any other *stage* without first
  un-retiring it back to `discovery`).
  """

  use TradingOptionsSimWeb, :live_view

  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.SimActivator

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Strategy Versions")
     |> assign(:stage_filter, nil)
     |> assign(:tagging_version_id, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    stage_filter =
      case params["stage"] do
        s when s in ["discovery", "quarantine", "test_portfolio", "retired"] -> s
        _ -> nil
      end

    {:noreply, socket |> assign(:stage_filter, stage_filter) |> load_versions()}
  end

  @impl true
  def handle_event("toggle_tag_control", %{"id" => id}, socket) do
    next_id = if socket.assigns.tagging_version_id == id, do: nil, else: id
    {:noreply, assign(socket, :tagging_version_id, next_id)}
  end

  def handle_event("add_tag", %{"version_id" => version_id, "tag_name" => tag_name}, socket) do
    trimmed = String.trim(tag_name)

    if trimmed == "" do
      {:noreply, socket}
    else
      version = Sim.get_strategy_version!(version_id)
      {:ok, _version} = Sim.add_tag_to_strategy_version_by_name(version, trimmed)
      {:noreply, load_versions(socket)}
    end
  end

  def handle_event("remove_tag", %{"id" => id, "tag_id" => tag_id}, socket) do
    version = Sim.get_strategy_version!(id) |> TradingOptionsSim.Repo.preload(:tags)
    remaining_ids = version.tags |> Enum.reject(&(&1.id == tag_id)) |> Enum.map(& &1.id)
    {:ok, _version} = Sim.put_strategy_version_tags(version, remaining_ids)
    {:noreply, load_versions(socket)}
  end

  def handle_event("activate", %{"id" => id}, socket) do
    version = Sim.get_strategy_version!(id)

    socket =
      case SimActivator.activate(version) do
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

    {:noreply, load_versions(socket)}
  end

  def handle_event("deactivate", %{"id" => id}, socket) do
    version = Sim.get_strategy_version!(id)
    {:ok, count} = SimActivator.deactivate(version)

    {:noreply,
     socket
     |> put_flash(:info, "Deactivated — #{count} monitor(s) stopped")
     |> load_versions()}
  end

  defp load_versions(socket) do
    socket
    |> assign(:versions, Sim.list_strategy_versions(socket.assigns.stage_filter))
    |> assign(:active_version_ids, Sim.active_strategy_version_ids())
    |> assign(:stage_counts, Sim.strategy_version_stage_counts())
  end

  defp filter_link_class(current, target) do
    base =
      "px-2 py-1 border font-data text-xs uppercase tracking-wide hover:border-primary/40 hover:text-primary"

    if current == target do
      base <> " border-primary/40 text-primary bg-primary/10"
    else
      base <> " border-transparent text-base-content/60"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center justify-between mb-6">
        <div class="flex items-center gap-4">
          <h1 class="text-2xl font-bold uppercase tracking-wide">Strategy Versions</h1>
          <.stage_counts_strip counts={@stage_counts} />
        </div>

        <div class="flex gap-1">
          <.link patch={~p"/strategy_versions"} class={filter_link_class(@stage_filter, nil)}>
            All
          </.link>
          <.link
            patch={~p"/strategy_versions?stage=discovery"}
            class={filter_link_class(@stage_filter, "discovery")}
          >
            Discovery
          </.link>
          <.link
            patch={~p"/strategy_versions?stage=quarantine"}
            class={filter_link_class(@stage_filter, "quarantine")}
          >
            Quarantine
          </.link>
          <.link
            patch={~p"/strategy_versions?stage=test_portfolio"}
            class={filter_link_class(@stage_filter, "test_portfolio")}
          >
            Test Portfolio
          </.link>
          <.link
            patch={~p"/strategy_versions?stage=retired"}
            class={filter_link_class(@stage_filter, "retired")}
          >
            Retired
          </.link>
        </div>
      </div>

      <div :if={@versions == []} class="border border-base-300 p-8 text-center">
        <p class="font-data text-sm uppercase tracking-wide text-base-content/40">
          No strategy versions to show
        </p>
      </div>

      <div :if={@versions != []} class="flex flex-col gap-px bg-base-300">
        <div :for={version <- @versions} class="bg-base-100 p-4">
          <div class="flex items-center gap-2 mb-2">
            <h2 class="font-bold uppercase tracking-wide">
              {version.strategy.name} <span class="text-base-content/40">v{version.version}</span>
            </h2>
            <.lifecycle_badge stage={version.lifecycle_stage} />
            <span
              :if={MapSet.member?(@active_version_ids, version.id)}
              class="inline-flex items-center gap-1 px-1.5 py-0.5 border border-success/40 text-success bg-success/10 text-[11px] uppercase tracking-wide font-data"
            >
              <span class="signal-dot relative w-1.5 h-1.5 rounded-full bg-success"></span> Active
            </span>

            <button
              :if={MapSet.member?(@active_version_ids, version.id)}
              type="button"
              phx-click="deactivate"
              phx-value-id={version.id}
              data-confirm="Deactivate this version? Any open position will be flattened and every running monitor stopped."
              class="px-1.5 py-0.5 border border-error/40 text-error bg-error/10 text-[11px] uppercase tracking-wide hover:bg-error/20"
            >
              Deactivate
            </button>
            <button
              :if={!MapSet.member?(@active_version_ids, version.id)}
              type="button"
              phx-click="activate"
              phx-value-id={version.id}
              class="px-1.5 py-0.5 border border-success/40 text-success bg-success/10 text-[11px] uppercase tracking-wide hover:bg-success/20"
            >
              Activate
            </button>

            <button
              type="button"
              phx-click="toggle_tag_control"
              phx-value-id={version.id}
              class="ml-auto text-base-content/40 hover:text-primary"
              title="Manage tags"
            >
              <.icon name="hero-tag" class="h-4 w-4" />
            </button>
          </div>

          <div class="flex flex-wrap items-center gap-1.5">
            <span
              :for={tag <- version.tags}
              class="inline-flex items-center gap-1 px-1.5 py-0.5 border border-secondary/40 text-secondary bg-secondary/10 text-[11px] uppercase tracking-wide font-data"
            >
              {tag.name}
              <button
                type="button"
                phx-click="remove_tag"
                phx-value-id={version.id}
                phx-value-tag_id={tag.id}
                class="hover:text-error"
              >
                <.icon name="hero-x-mark" class="h-3 w-3" />
              </button>
            </span>

            <form
              :if={@tagging_version_id == version.id}
              phx-submit="add_tag"
              class="inline-flex"
            >
              <input type="hidden" name="version_id" value={version.id} />
              <input
                type="text"
                name="tag_name"
                placeholder="add tag…"
                class="input input-xs input-bordered font-data text-[11px]"
                autofocus
              />
            </form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
