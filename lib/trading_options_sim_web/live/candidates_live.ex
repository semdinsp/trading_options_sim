defmodule TradingOptionsSimWeb.CandidatesLive do
  @moduledoc """
  Ranks `discovery`/`quarantine`-stage `StrategyVersion`s for promotion
  to quarantine/test_portfolio, sorted by `lcb95` (one-sided 95% lower
  confidence bound) descending by default — deliberately not
  `expectancy_r`, which rewards a thin, lucky sample over a large,
  merely-good one. Ported from `trading_system`'s own `CandidatesLive`
  (confirmed by reading that module directly): same default filter
  (discovery+quarantine, `n_closes >= 30`), same "Show all"/"Near-miss"
  toggles, same nine-gate letter strip (`TradingOptionsSim.CandidateGates`),
  same "no promote button here — gates are advisory triage, not
  enforcement" posture (the real promote action stays on
  `StrategyVersionsLive`'s own button, ungated by any of this).

  **No URL/query-param state** — same choice the source page makes
  (confirmed: no `handle_params/3`, no `push_patch` anywhere in that
  file). Every filter/sort/expand toggle lives purely in socket
  assigns, reset to defaults on reload.

  Data is computed fresh from live `SimRun`/`SimFill` data on every
  mount/refresh (`Sim.full_universe_version_metrics/0`), not read from
  `PerformanceSnapshot` — that table is a once-daily historical rollup;
  this triage page needs current state.

  `expectancy_r`/`lcb95`/`ucb95` here are dollar-R-multiples using
  `SimRun.risk_at_entry` = entry premium at risk (`entry_price *
  multiplier * quantity`) as the risk denominator — see
  `Sim.compute_risk_at_entry/3`'s own `TODO` for why (no strategy in
  this app sets a real stop-loss yet).
  """

  use TradingOptionsSimWeb, :live_view

  alias TradingOptionsSim.CandidateGates
  alias TradingOptionsSim.Sim

  @sample_floor 30
  @refresh_ms :timer.seconds(30)

  @default_sort_dir %{"gates_failed" => :asc}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Candidates")
     |> assign(:show_all?, false)
     |> assign(:near_miss_only?, false)
     |> assign(:tag_filter, nil)
     |> assign(:tags, Sim.list_tags())
     |> assign(:sort_by, "lcb95")
     |> assign(:sort_dir, :desc)
     |> assign(:expanded_ids, MapSet.new())
     |> assign(:stage_counts, Sim.strategy_version_stage_counts())
     |> assign(:sample_floor, @sample_floor)
     |> assign_candidates()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply,
     socket
     |> assign(:stage_counts, Sim.strategy_version_stage_counts())
     |> assign_candidates()}
  end

  @impl true
  def handle_event("toggle_show_all", _params, socket) do
    {:noreply, socket |> assign(:show_all?, !socket.assigns.show_all?) |> assign_candidates()}
  end

  def handle_event("toggle_near_miss", _params, socket) do
    {:noreply,
     socket |> assign(:near_miss_only?, !socket.assigns.near_miss_only?) |> assign_candidates()}
  end

  def handle_event("filter_tag", %{"tag_id" => "all"}, socket) do
    {:noreply, socket |> assign(:tag_filter, nil) |> assign_candidates()}
  end

  def handle_event("filter_tag", %{"tag_id" => tag_id}, socket) do
    {:noreply, socket |> assign(:tag_filter, tag_id) |> assign_candidates()}
  end

  def handle_event("sort_by", %{"sort_by" => sort_by}, socket) do
    sort_dir =
      if socket.assigns.sort_by == sort_by do
        flip(socket.assigns.sort_dir)
      else
        Map.get(@default_sort_dir, sort_by, :desc)
      end

    {:noreply,
     socket |> assign(:sort_by, sort_by) |> assign(:sort_dir, sort_dir) |> assign_candidates()}
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    expanded_ids =
      if MapSet.member?(socket.assigns.expanded_ids, id) do
        MapSet.delete(socket.assigns.expanded_ids, id)
      else
        MapSet.put(socket.assigns.expanded_ids, id)
      end

    {:noreply, assign(socket, :expanded_ids, expanded_ids)}
  end

  defp flip(:asc), do: :desc
  defp flip(:desc), do: :asc

  defp assign_candidates(socket) do
    now = DateTime.utc_now()

    rows =
      Sim.full_universe_version_metrics()
      |> Enum.map(fn row ->
        gates = CandidateGates.evaluate(row, now)

        Map.merge(row, %{
          gates: gates,
          candidate?: CandidateGates.candidate?(gates),
          blocked_only_by_tenure?: CandidateGates.blocked_only_by_tenure?(gates),
          gates_failed: CandidateGates.gates_failed(gates)
        })
      end)

    total_unfiltered = length(rows)

    filtered =
      rows
      |> maybe_filter_sample_floor(socket.assigns.show_all?)
      |> maybe_filter_near_miss(socket.assigns.near_miss_only?)
      |> maybe_filter_tag(socket.assigns.tag_filter)
      |> sort_rows(socket.assigns.sort_by, socket.assigns.sort_dir)

    socket
    |> assign(:rows, filtered)
    |> assign(:total_unfiltered, total_unfiltered)
  end

  defp maybe_filter_sample_floor(rows, true), do: rows

  defp maybe_filter_sample_floor(rows, false),
    do: Enum.filter(rows, &(&1.n_closes >= @sample_floor))

  defp maybe_filter_near_miss(rows, false), do: rows
  defp maybe_filter_near_miss(rows, true), do: Enum.filter(rows, &(&1.gates_failed in 1..2))

  defp maybe_filter_tag(rows, nil), do: rows

  defp maybe_filter_tag(rows, tag_id) do
    Enum.filter(rows, fn row -> Enum.any?(row.tags, &(&1.id == tag_id)) end)
  end

  defp sort_rows(rows, sort_by, sort_dir) do
    key = String.to_existing_atom(sort_by)

    Enum.sort_by(rows, &sort_value(&1, key), sort_comparator(sort_dir))
  end

  # nil (never computed) always sorts last, regardless of direction —
  # matches the source page's own "unrated always sorts last" rule for
  # its `rating` column, generalized to every nullable numeric column
  # here (lcb95, ucb95, expectancy_r, cost_margin, rating).
  defp sort_value(row, key) do
    case Map.get(row, key) do
      nil -> {1, 0}
      %Decimal{} = value -> {0, Decimal.to_float(value)}
      value when is_number(value) -> {0, value}
      value -> {0, value}
    end
  end

  defp sort_comparator(:asc), do: :asc
  defp sort_comparator(:desc), do: :desc

  defp format_r(nil), do: "—"
  defp format_r(%Decimal{} = value), do: Decimal.round(value, 3) |> Decimal.to_string()
  defp format_r(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)

  defp format_price(nil), do: "—"
  defp format_price(%Decimal{} = value), do: "$#{Decimal.round(value, 2)}"

  defp format_hold_seconds(nil), do: "—"

  defp format_hold_seconds(%Decimal{} = seconds) do
    hours = Decimal.div(seconds, 3600) |> Decimal.round(1)
    "#{hours}h"
  end

  defp exit_histogram_label(histogram) when map_size(histogram) == 0, do: "—"

  defp exit_histogram_label(histogram) do
    histogram
    |> Enum.sort_by(fn {_reason, count} -> -count end)
    |> Enum.map_join(" / ", fn {reason, count} -> "#{reason} #{count}" end)
  end

  defp churn_label(n_closes, excluded_count, excluded_pnl) do
    total = n_closes + excluded_count
    pct = if total == 0, do: 0, else: round(excluded_count / total * 100)
    "#{excluded_count} (#{pct}%, #{format_price(excluded_pnl)})"
  end

  defp last_traded_label(nil), do: "never"

  defp last_traded_label(%DateTime{} = last_traded_on) do
    case DateTime.diff(DateTime.utc_now(), last_traded_on, :day) do
      0 -> "today"
      1 -> "1 day ago"
      n -> "#{n} days ago"
    end
  end

  defp gate_cell_class(:fail), do: "text-error"
  defp gate_cell_class(_verdict), do: nil

  defp gate_letter_class(:pass), do: "text-success"
  defp gate_letter_class(:fail), do: "text-error"
  defp gate_letter_class(:not_applicable), do: "text-base-content/20"
  defp gate_letter_class(:not_computed), do: "text-base-content/20"

  defp sort_link_class(current, target) do
    base = "hover:text-primary cursor-pointer select-none"
    if current == target, do: base <> " text-primary", else: base <> " text-base-content/60"
  end

  defp truncate_id(id), do: "#{String.slice(id, 0, 8)}…#{String.slice(id, -4, 4)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center gap-4 mb-2">
        <h1 class="text-2xl font-bold uppercase tracking-wide">Candidates</h1>
        <.stage_counts_strip counts={@stage_counts} />
        <span class="font-data text-xs text-base-content/40 ml-auto">
          {length(@rows)} of {@total_unfiltered} shown
        </span>
      </div>

      <div class="flex flex-wrap items-center gap-3 mb-3">
        <form id="tag-filter-form" phx-change="filter_tag" class="inline-flex">
          <select name="tag_id" class="select select-xs select-bordered font-data text-[11px]">
            <option value="all" selected={is_nil(@tag_filter)}>All Tags</option>
            <option :for={tag <- @tags} value={tag.id} selected={@tag_filter == tag.id}>
              {tag.name}
            </option>
          </select>
        </form>

        <button
          type="button"
          phx-click="toggle_show_all"
          class={[
            "px-2 py-1 border font-data text-xs uppercase tracking-wide",
            if(@show_all?,
              do: "border-primary/40 text-primary bg-primary/10",
              else:
                "border-transparent text-base-content/60 hover:border-primary/40 hover:text-primary"
            )
          ]}
        >
          Show all
        </button>

        <button
          type="button"
          phx-click="toggle_near_miss"
          class={[
            "px-2 py-1 border font-data text-xs uppercase tracking-wide",
            if(@near_miss_only?,
              do: "border-warning/40 text-warning bg-warning/10",
              else:
                "border-transparent text-base-content/60 hover:border-warning/40 hover:text-warning"
            )
          ]}
        >
          Near-miss
        </button>
      </div>

      <p class="text-xs text-base-content/50 mb-4 max-w-4xl">
        Sorted by <span class="font-data">{@sort_by}</span>
        ({@sort_dir}) — click a column header to change. Default sort is
        <span class="font-data">lcb95</span>
        (one-sided 95% lower bound) descending, not <span class="font-data">expectancy_r</span>
        , which rewards thin samples. A row must pass every gate to be a candidate; gate letters
        below show which, if any, still fail. Default filter: discovery + quarantine,
        n_closes ≥ {@sample_floor} — use "Show all" to see near-misses too, or "Near-miss" to jump
        straight to versions failing exactly 1-2 gates.
      </p>

      <div :if={@rows == []} class="border border-base-300 p-8 text-center">
        <p class="font-data text-sm uppercase tracking-wide text-base-content/40">
          No candidates match the current filters
        </p>
      </div>

      <div :if={@rows != []} class="border border-base-300 overflow-x-auto">
        <table class="table font-data text-[11px]">
          <thead class="bg-base-300 uppercase tracking-wide">
            <tr>
              <th>Strategy</th>
              <th>v</th>
              <th>Stage</th>
              <th>Dir</th>
              <th>Pool</th>
              <th>Tags</th>
              <th
                phx-click="sort_by"
                phx-value-sort_by="n_closes"
                class={sort_link_class(@sort_by, "n_closes")}
              >
                n
              </th>
              <th
                phx-click="sort_by"
                phx-value-sort_by="expectancy_r"
                class={sort_link_class(@sort_by, "expectancy_r")}
              >
                expectancy_r
              </th>
              <th
                phx-click="sort_by"
                phx-value-sort_by="lcb95"
                class={sort_link_class(@sort_by, "lcb95")}
              >
                lcb95
              </th>
              <th>ucb95</th>
              <th
                phx-click="sort_by"
                phx-value-sort_by="cost_margin"
                class={sort_link_class(@sort_by, "cost_margin")}
              >
                cost_margin
              </th>
              <th
                phx-click="sort_by"
                phx-value-sort_by="realized_pnl"
                class={sort_link_class(@sort_by, "realized_pnl")}
              >
                realized_pnl
              </th>
              <th
                phx-click="sort_by"
                phx-value-sort_by="r_per_capital_hour"
                class={sort_link_class(@sort_by, "r_per_capital_hour")}
              >
                $/cap-hr
              </th>
              <th>Avg hold</th>
              <th>Exits</th>
              <th>Churn</th>
              <th>Last traded</th>
              <th>Q days</th>
              <th>Gates</th>
              <th
                phx-click="sort_by"
                phx-value-sort_by="gates_failed"
                class={sort_link_class(@sort_by, "gates_failed")}
              >
                Gates failed
              </th>
              <th>Version ID</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} class={row.candidate? && "bg-success/5"}>
              <td>
                <.link
                  navigate={~p"/strategy_versions/#{row.strategy_version_id}"}
                  class="hover:text-primary font-bold"
                >
                  {row.strategy_name}
                </.link>
                <span :if={row.blocked_only_by_tenure?} class="ml-1 text-warning normal-case">tenure-only</span>
              </td>
              <td>v{row.version}</td>
              <td><.lifecycle_badge stage={row.lifecycle_stage} /></td>
              <td class="uppercase">{row.direction}</td>
              <td>{row.target_pool_name || "—"}</td>
              <td>
                <span
                  :for={tag <- row.tags}
                  class="inline-block px-1 py-0.5 mr-1 border border-secondary/40 text-secondary bg-secondary/10 text-[10px] uppercase"
                >
                  {tag.name}
                </span>
              </td>
              <td class={["text-right tabular-nums", gate_cell_class(row.gates.sample_floor)]}>
                {row.n_closes}
              </td>
              <td class="text-right tabular-nums">{format_r(row.expectancy_r)}</td>
              <td class={["text-right tabular-nums font-bold", gate_cell_class(row.gates.statistical)]}>
                {format_r(row.lcb95)}
              </td>
              <td class="text-right tabular-nums">{format_r(row.ucb95)}</td>
              <td class={["text-right tabular-nums", gate_cell_class(row.gates.economic)]}>
                {format_r(row.cost_margin)}
              </td>
              <td class={["text-right tabular-nums", gate_cell_class(row.gates.dollars_agree)]}>
                {format_price(row.realized_pnl)}
              </td>
              <td class="text-right tabular-nums">{format_r(row.r_per_capital_hour)}</td>
              <td class="text-right tabular-nums">{format_hold_seconds(row.avg_hold_seconds)}</td>
              <td class={["normal-case", gate_cell_class(row.gates.exit_logic)]}>
                {exit_histogram_label(row.exit_reason_histogram)}
              </td>
              <td class={["normal-case", gate_cell_class(row.gates.churn)]}>
                {churn_label(row.n_closes, row.excluded_count, row.excluded_pnl)}
              </td>
              <td class={["normal-case", gate_cell_class(row.gates.recency)]}>
                {last_traded_label(row.last_traded_on)}
              </td>
              <td class={["text-right tabular-nums", gate_cell_class(row.gates.quarantine_tenure)]}>
                {row.quarantine_trading_days}
              </td>
              <td>
                <span
                  :for={gate <- CandidateGates.gate_order()}
                  class={["mr-0.5", gate_letter_class(Map.fetch!(row.gates, gate))]}
                  title={to_string(gate)}
                >
                  {CandidateGates.gate_letter(gate)}
                </span>
              </td>
              <td class="text-right tabular-nums">{row.gates_failed}</td>
              <td>
                <button
                  type="button"
                  phx-click="toggle_expand"
                  phx-value-id={row.strategy_version_id}
                  class="text-base-content/50 hover:text-primary normal-case"
                >
                  {truncate_id(row.strategy_version_id)}
                </button>
                <div
                  :if={MapSet.member?(@expanded_ids, row.strategy_version_id)}
                  class="normal-case text-base-content/40 mt-1"
                >
                  <div>strategy: {row.strategy_id}</div>
                  <div :if={row.target_pool_id}>pool: {row.target_pool_id}</div>
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
