defmodule TradingOptionsSimWeb.StrategySearchLiveTest do
  use TradingOptionsSimWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TradingOptionsSim.Sim

  # Two strategies with distinctive names; each page must filter to one
  # of them by name, and to the other by a UUID prefix.
  defp version(name) do
    {:ok, strategy} = Sim.create_strategy(%{name: name})

    {:ok, v} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    v
  end

  defp search(view, q), do: view |> form("#strategy-search", %{q: q}) |> render_change()

  # Our ids are UUIDv7: the first 8 hex chars are a millisecond
  # timestamp, so rows created together share that prefix. The random
  # TAIL is what picks out one row, and the search is a substring match.
  defp tail(uuid), do: String.slice(uuid, -12, 12)

  test "strategy versions page filters by name and by a UUID fragment", %{conn: conn} do
    a = version("Zebra Alpha Trend")
    b = version("Yak Beta Fade")

    {:ok, view, _} = live(conn, ~p"/strategy_versions")
    assert search(view, "zebra") =~ "Zebra Alpha Trend"
    refute search(view, "zebra") =~ "Yak Beta Fade"

    html = search(view, tail(b.id))
    assert html =~ "Yak Beta Fade"
    refute html =~ "Zebra Alpha Trend"

    assert search(view, "") =~ "Zebra Alpha Trend"
    _ = a
  end

  test "active strategies page filters by name", %{conn: conn} do
    {:ok, a} = Sim.mark_activated(version("Zebra Active One"))
    {:ok, _b} = Sim.mark_activated(version("Yak Active Two"))

    {:ok, view, _} = live(conn, ~p"/active_strategies")
    html = search(view, "zebra")
    assert html =~ "Zebra Active One"
    refute html =~ "Yak Active Two"

    html = search(view, a.id)
    assert html =~ "Zebra Active One"
    refute html =~ "Yak Active Two"
  end

  test "runs page filters by strategy name and by run id", %{conn: conn} do
    open = fn v ->
      {:ok, run} =
        Sim.open_sim_run(v, %{
          symbol: "SRCH",
          expiry: "20271231",
          strike: Decimal.new("150.00"),
          right: "C",
          multiplier: 100,
          direction: "long"
        })

      run
    end

    _run_a = open.(version("Zebra Runner"))
    run_b = open.(version("Yak Runner"))

    {:ok, view, _} = live(conn, ~p"/runs")
    html = search(view, "zebra")
    assert html =~ "Zebra Runner"
    refute html =~ "Yak Runner"

    html = search(view, tail(run_b.id))
    assert html =~ "Yak Runner"
    refute html =~ "Zebra Runner"
  end

  test "candidates page filters by name and by version id", %{conn: conn} do
    _a = version("Zebra Candidate")
    b = version("Yak Candidate")

    {:ok, view, _} = live(conn, ~p"/candidates")
    # Brand-new versions are below the sample floor; show everything.
    view |> element("button[phx-click=toggle_show_all]") |> render_click()

    html = search(view, "zebra")
    assert html =~ "Zebra Candidate"
    refute html =~ "Yak Candidate"

    html = search(view, tail(b.id))
    assert html =~ "Yak Candidate"
    refute html =~ "Zebra Candidate"
  end
end
