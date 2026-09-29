defmodule TradingOptionsSimWeb.RunsLiveTest do
  use TradingOptionsSimWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TradingOptionsSim.Sim

  defp strategy_fixture do
    {:ok, strategy} = Sim.create_strategy(%{name: "Test Strategy"})
    strategy
  end

  defp version_fixture(strategy, attrs \\ %{}) do
    {:ok, version} =
      Sim.create_strategy_version(
        strategy,
        Map.merge(%{version: 1, position_sizing: %{"method" => "fixed_qty", "qty" => 1}}, attrs)
      )

    version
  end

  defp run_fixture(version) do
    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: "AAPL",
        expiry: "20271231",
        strike: Decimal.new("150.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

    run
  end

  test "lists every run", %{conn: conn} do
    strategy = strategy_fixture()
    version = version_fixture(strategy)
    run_fixture(version)

    {:ok, _view, html} = live(conn, ~p"/runs")
    assert html =~ "AAPL"
  end

  test "shows cost, fees, net and return for a run with recorded fills", %{conn: conn} do
    strategy = strategy_fixture()
    version = version_fixture(strategy)
    run = run_fixture(version)
    now = DateTime.utc_now()

    {:ok, {_fill, run}} =
      Sim.record_entry_fill(
        run,
        %{
          action: "buy",
          quantity: 1,
          fill_price: Decimal.new("5.00"),
          filled_at: now,
          commission: Decimal.new("1.68")
        },
        %{entry_at: now, entry_price: Decimal.new("5.00")}
      )

    {:ok, {_fill, _run}} =
      Sim.record_exit_fill(
        run,
        %{
          action: "sell",
          quantity: 1,
          fill_price: Decimal.new("6.00"),
          filled_at: now,
          commission: Decimal.new("1.68")
        },
        %{
          exit_at: now,
          exit_price: Decimal.new("6.00"),
          exit_reason: "target_hit",
          realized_pnl: Decimal.new("100.00"),
          realized_pnl_net: Decimal.new("96.64")
        }
      )

    {:ok, _view, html} = live(conn, ~p"/runs")

    assert html =~ "Fees"
    assert html =~ "$3.36"
    # $5.00/share x 100 shares x 1 contract: the premium paid, and for a
    # long the capital at risk.
    assert html =~ "$500.00"
    assert html =~ "$96.64"
    # 96.64 / 500
    assert html =~ "19.3%"
  end

  test "shows a dash for fees when a run has no fills yet", %{conn: conn} do
    strategy = strategy_fixture()
    version = version_fixture(strategy)
    run_fixture(version)

    {:ok, _view, html} = live(conn, ~p"/runs")

    assert html =~ "Fees"
    assert html =~ "—"
  end

  describe "filters" do
    test "filters to open runs", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      run_fixture(version)

      {:ok, _view, html} = live(conn, ~p"/runs?status=open")
      assert html =~ "AAPL"
    end

    test "filters to closed runs excludes an open one", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      run_fixture(version)

      {:ok, _view, html} = live(conn, ~p"/runs?status=closed")
      refute html =~ "AAPL"
    end
  end

  describe "tagging" do
    test "toggling the tag control shows the add-tag form", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      run = run_fixture(version)

      {:ok, view, _html} = live(conn, ~p"/runs")

      html =
        view
        |> element("button[phx-click=toggle_tag_control][phx-value-id='#{run.id}']")
        |> render_click()

      assert html =~ "add tag"
    end

    test "adding a tag shows the chip", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      run = run_fixture(version)

      {:ok, view, _html} = live(conn, ~p"/runs")

      view
      |> element("button[phx-click=toggle_tag_control][phx-value-id='#{run.id}']")
      |> render_click()

      html =
        view
        |> form("form[phx-submit=add_tag]", %{"run_id" => run.id, "tag_name" => "hot"})
        |> render_submit()

      assert html =~ "hot"
    end

    test "removing a tag hides the chip", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      run = run_fixture(version)
      {:ok, run} = Sim.add_tag_to_run_by_name(run, "hot")
      tag = hd(run.tags)

      {:ok, view, html} = live(conn, ~p"/runs")
      assert html =~ "hot"

      html =
        view
        |> element(
          "button[phx-click=remove_tag][phx-value-id='#{run.id}'][phx-value-tag_id='#{tag.id}']"
        )
        |> render_click()

      refute html =~ "hot"
    end
  end

  describe "pagination" do
    alias TradingOptionsSim.Sim

    # Runs P000..P0nn, oldest first; the page lists newest first.
    defp runs(version, count) do
      for i <- 0..(count - 1) do
        {:ok, run} =
          Sim.open_sim_run(version, %{
            symbol: "P" <> String.pad_leading(to_string(i), 3, "0"),
            expiry: "20271231",
            strike: Decimal.new("150.00"),
            right: "C",
            multiplier: 100,
            direction: "long"
          })

        run
      end
    end

    # Runs created together share a timestamp, so check that the two
    # pages together show every run exactly once rather than an order.
    test "shows 50 runs per page, with a range and page links", %{conn: conn} do
      runs(version_fixture(strategy_fixture()), 60)
      symbols = fn html -> Regex.scan(~r/>(P\d{3}) /, html) |> Enum.map(fn [_, s] -> s end) end

      {:ok, view, html} = live(conn, ~p"/runs")
      assert html =~ "1–50 of 60"
      assert html =~ "Page 1 of 2"
      page1 = symbols.(html)
      assert length(page1) == 50

      html = view |> element("#pager-top a", "Next →") |> render_click()
      assert_patch(view, ~p"/runs?page=2")
      assert html =~ "51–60 of 60"
      page2 = symbols.(html)
      assert length(page2) == 10
      assert has_element?(view, "#pager-top a", "← Prev")

      assert Enum.sort(page1 ++ page2) ==
               Enum.map(0..59, &("P" <> String.pad_leading(to_string(&1), 3, "0")))
    end

    test "the status filter pages within its own results", %{conn: conn} do
      version = version_fixture(strategy_fixture())
      runs(version, 3)

      {:ok, _view, html} = live(conn, ~p"/runs?status=closed")
      assert html =~ "No runs to show"

      {:ok, _view, html} = live(conn, ~p"/runs?status=open&page=1")
      assert html =~ "1–3 of 3"
    end

    # An older page must not shift under the reader.
    test "only page 1 refreshes on the timer", %{conn: conn} do
      version = version_fixture(strategy_fixture())
      runs(version, 51)

      {:ok, view, _html} = live(conn, ~p"/runs?page=2")
      assert render(view) =~ "51–51 of 51"

      Sim.open_sim_run(version, %{
        symbol: "NEWER",
        expiry: "20271231",
        strike: Decimal.new("150.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

      send(view.pid, :refresh)
      assert render(view) =~ "51–51 of 51"

      {:ok, view, _html} = live(conn, ~p"/runs")
      send(view.pid, :refresh)
      assert render(view) =~ "of 52"
    end

    test "a search is applied in the query and returns to page 1", %{conn: conn} do
      runs(version_fixture(strategy_fixture()), 55)
      {:ok, other} = Sim.create_strategy(%{name: "Needle Strategy"})
      [needle] = runs(version_fixture(other), 1)

      {:ok, view, _html} = live(conn, ~p"/runs?page=2")
      html = view |> form("form[phx-change=search]", %{q: "needle"}) |> render_change()
      assert_patch(view, ~p"/runs")
      assert html =~ "1–1 of 1"
      assert html =~ "Needle Strategy"

      # A UUID fragment matches the run's own id (its random tail).
      html =
        view
        |> form("form[phx-change=search]", %{q: String.slice(needle.id, -12, 12)})
        |> render_change()

      assert html =~ "1–1 of 1"
    end
  end
end
