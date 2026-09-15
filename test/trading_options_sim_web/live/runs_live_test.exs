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

  test "shows the estimated commission column for a run with recorded fills", %{conn: conn} do
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

    assert html =~ "Est. Commission"
    assert html =~ "$3.36"
  end

  test "shows a dash for the estimated commission when a run has no fills yet", %{conn: conn} do
    strategy = strategy_fixture()
    version = version_fixture(strategy)
    run_fixture(version)

    {:ok, _view, html} = live(conn, ~p"/runs")

    assert html =~ "Est. Commission"
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
end
