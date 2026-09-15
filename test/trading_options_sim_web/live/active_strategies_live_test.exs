defmodule TradingOptionsSimWeb.ActiveStrategiesLiveTest do
  use TradingOptionsSimWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TradingOptionsSim.Sim

  test "shows an empty state with no active versions", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/active_strategies")
    assert html =~ "No strategy versions currently have an open run"
  end

  test "shows a symbol chip and lifecycle badge for a version with an open run", %{conn: conn} do
    {:ok, strategy} = Sim.create_strategy(%{name: "Test Strategy"})
    {:ok, pool} = Sim.create_target_pool(%{name: "Test Pool"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{},
        target_pool_id: pool.id
      })

    {:ok, version} = Sim.promote_strategy_version(version, "quarantine")
    {:ok, version} = Sim.mark_activated(version)

    {:ok, _run} =
      Sim.open_sim_run(version, %{
        symbol: "AAPL",
        expiry: "20271231",
        strike: Decimal.new("150.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

    {:ok, _view, html} = live(conn, ~p"/active_strategies")

    assert html =~ "Test Strategy"
    assert html =~ "AAPL"
    assert html =~ "quarantine"
  end

  test "does not show a retired version even if it was never explicitly deactivated", %{
    conn: conn
  } do
    {:ok, strategy} = Sim.create_strategy(%{name: "Retired Strategy"})
    {:ok, pool} = Sim.create_target_pool(%{name: "Retired Pool"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{},
        target_pool_id: pool.id
      })

    {:ok, version} = Sim.promote_strategy_version(version, "quarantine")
    {:ok, version} = Sim.mark_activated(version)
    {:ok, _retired} = Sim.downgrade_strategy_version(version, "retired")

    {:ok, _view, html} = live(conn, ~p"/active_strategies")

    refute html =~ "Retired Strategy"
    assert html =~ "No strategy versions currently have an open run"
  end

  test "the home page is Active Strategies", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Active Strategies"
  end

  test "shows the stage counts strip", %{conn: conn} do
    {:ok, strategy} = Sim.create_strategy(%{name: "Test Strategy"})

    {:ok, _version} =
      Sim.create_strategy_version(strategy, %{version: 1, position_sizing: %{}})

    {:ok, _view, html} = live(conn, ~p"/active_strategies")

    assert html =~ "D 1"
    assert html =~ "Q 0"
  end
end
