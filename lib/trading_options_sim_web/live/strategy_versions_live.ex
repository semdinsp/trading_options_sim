defmodule TradingOptionsSimWeb.StrategyVersionsLive do
  @moduledoc """
  Every `StrategyVersion` across every strategy, filterable by
  `lifecycle_stage` — the one list that also serves as the
  retired-strategies view (a `?stage=retired` filter, not a separate
  screen — `Sim.list_strategy_versions/1` already covers every stage
  through one query). "All" (no `stage` param) is retired-versions-
  excluded by default — retired versions are opt-in, only shown by
  explicitly clicking the "Retired" filter — so they don't clutter the
  default landing view; see `list_versions/1`. Each row shows its tag
  chips and an inline add/remove tag control, per
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §3a —
  and an Activate/Deactivate button (`SimActivator.activate/1` /
  `.deactivate/1`), independent of `lifecycle_stage`: "activated" means
  "has running monitors," not a stage transition, so a version can be
  (de)activated at any stage, including `retired` (deactivating a
  version nobody got around to before retiring it is still a real,
  useful action; re-activating a retired one is intentionally still
  allowed here even though `Sim.promote_strategy_version/2` wouldn't
  let a retired version move to any other *stage* without first
  un-retiring it back to `discovery`).

  Each row also has a `trading_hours_policy` dropdown and an
  `overnight_hold` toggle — ported from `trading_live`'s own identical
  per-strategy settings (see `StrategyVersion.trading_hours_policies/0`
  and `Sim.update_trading_hours_settings/2` for the full mapping).
  """

  use TradingOptionsSimWeb, :live_view

  alias TradingOptionsSimWeb.StrategySearch

  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.StrategyVersion
  alias TradingOptionsSim.SimActivator

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Strategy Versions")
     |> assign(:search, "")
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
  # Shared search box (<.search_box>): strategy name or UUID fragment,
  # see TradingOptionsSimWeb.StrategySearch. Applied inside the load step
  # so it survives the periodic refresh.
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search, q) |> load_versions()}
  end

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
    version = Sim.get_strategy_version!(id)
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

  def handle_event("retire", %{"id" => id}, socket) do
    version = Sim.get_strategy_version!(id)

    socket =
      case Sim.downgrade_strategy_version(version, "retired") do
        {:ok, _retired} -> put_flash(socket, :info, "Retired")
        {:error, _reason} -> put_flash(socket, :error, "Could not retire this version")
      end

    {:noreply, load_versions(socket)}
  end

  def handle_event("unretire", %{"id" => id}, socket) do
    version = Sim.get_strategy_version!(id)

    socket =
      case Sim.promote_strategy_version(version, "discovery") do
        {:ok, _unretired} -> put_flash(socket, :info, "Unretired — back to discovery")
        {:error, _reason} -> put_flash(socket, :error, "Could not unretire this version")
      end

    {:noreply, load_versions(socket)}
  end

  def handle_event(
        "set_trading_hours_policy",
        %{"version_id" => id, "policy" => policy},
        socket
      ) do
    version = Sim.get_strategy_version!(id)
    {:ok, _version} = Sim.update_trading_hours_settings(version, %{trading_hours_policy: policy})
    {:noreply, load_versions(socket)}
  end

  def handle_event("toggle_overnight_hold", %{"id" => id}, socket) do
    version = Sim.get_strategy_version!(id)

    {:ok, _version} =
      Sim.update_trading_hours_settings(version, %{overnight_hold: !version.overnight_hold})

    {:noreply, load_versions(socket)}
  end

  defp load_versions(socket) do
    socket
    |> assign(
      :versions,
      socket.assigns.stage_filter
      |> list_versions()
      |> StrategySearch.filter(
        socket.assigns.search,
        &{&1.strategy.name, [&1.id, &1.strategy_id]}
      )
    )
    |> assign(:active_version_ids, Sim.active_strategy_version_ids())
    |> assign(:stage_counts, Sim.strategy_version_stage_counts())
  end

  # "All" (stage_filter nil) deliberately excludes retired versions —
  # retired is opt-in via the explicit "Retired" filter button, not
  # something that should clutter the default landing view. Any other
  # explicit stage_filter (including "retired" itself) passes straight
  # through to Sim.list_strategy_versions/1 unchanged.
  defp list_versions(nil) do
    Sim.list_strategy_versions(nil) |> Enum.reject(&(&1.lifecycle_stage == "retired"))
  end

  defp list_versions(stage_filter), do: Sim.list_strategy_versions(stage_filter)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center justify-between mb-6">
        <div class="flex items-center gap-4">
          <h1 class="text-2xl font-bold uppercase tracking-wide">Strategy Versions</h1>
          <.stage_counts_strip counts={@stage_counts} />
          <.search_box query={@search} />
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
            <.link
              navigate={~p"/strategy_versions/#{version.id}"}
              class="font-bold uppercase tracking-wide hover:text-primary"
            >
              <h2 class="inline">
                {version.strategy.name} <span class="text-base-content/40">v{version.version}</span>
              </h2>
            </.link>
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

            <.retire_button stage={version.lifecycle_stage} version_id={version.id} />

            <button
              type="button"
              phx-click="toggle_tag_control"
              phx-value-id={version.id}
              class="ml-auto text-base-content/40 hover:text-primary"
              title="Manage tags"
              aria-label="Manage tags"
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
              <label for={"add-tag-input-#{version.id}"} class="sr-only">Add tag</label>
              <input
                type="text"
                id={"add-tag-input-#{version.id}"}
                name="tag_name"
                placeholder="add tag…"
                class="input input-xs input-bordered font-data text-[11px]"
                autofocus
              />
            </form>
          </div>

          <div class="flex items-center gap-3 mt-2">
            <form
              id={"trading-hours-form-#{version.id}"}
              phx-change="set_trading_hours_policy"
              class="inline-flex items-center gap-1"
            >
              <input type="hidden" name="version_id" value={version.id} />
              <label
                for={"trading-hours-#{version.id}"}
                class="text-[11px] uppercase text-base-content/40 font-data"
              >
                Hours
              </label>
              <select
                id={"trading-hours-#{version.id}"}
                name="policy"
                class="select select-xs select-bordered font-data text-[11px]"
              >
                <option
                  :for={policy <- StrategyVersion.trading_hours_policies()}
                  value={policy}
                  selected={policy == version.trading_hours_policy}
                >
                  {StrategyVersion.trading_hours_policy_label(policy)}
                </option>
              </select>
            </form>

            <button
              type="button"
              phx-click="toggle_overnight_hold"
              phx-value-id={version.id}
              class={[
                "px-1.5 py-0.5 border text-[11px] uppercase tracking-wide font-data",
                if(version.overnight_hold,
                  do: "border-warning/40 text-warning bg-warning/10",
                  else:
                    "border-base-content/20 text-base-content/40 hover:border-warning/40 hover:text-warning"
                )
              ]}
              title="Exempt this version's open positions from automatic end-of-day close"
            >
              Overnight Hold: {if version.overnight_hold, do: "On", else: "Off"}
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
