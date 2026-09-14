defmodule TradingOptionsSimWeb.SystemPerformanceLiveTest do
  use TradingOptionsSimWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the Node Health and Cron / Oban Health panels", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/system-performance")

    assert html =~ "Node Health"
    assert html =~ "Cron / Oban Health"
    assert html =~ "QuarantineEligibilityWorker"
  end

  test "shows a Database stat (UP or DOWN)", %{conn: conn} do
    # AppStatus.Collector runs as its own long-lived process, started
    # once at application boot — it never checks out this (or any)
    # test's Ecto.Adapters.SQL.Sandbox connection, so
    # StatusExtension.db_up?/0's own query genuinely fails under
    # sandbox mode regardless of whether the real DB is reachable. This
    # only asserts the stat renders at all, not which value it shows.
    {:ok, _view, html} = live(conn, ~p"/system-performance")

    assert html =~ "Database"
    assert html =~ "UP" or html =~ "DOWN"
  end

  test "shows an active monitor count", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/system-performance")

    assert html =~ "Active Monitors"
  end

  test "a worker with no jobs shows NEVER RAN", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/system-performance")

    assert html =~ "NEVER RAN"
  end
end
