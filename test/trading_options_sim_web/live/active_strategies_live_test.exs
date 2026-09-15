defmodule TradingOptionsSimWeb.ActiveStrategiesLiveTest do
  # async: false — the live-current-price test starts a real
  # ContractMonitor (via SimActivator.activate/1) that does its own DB
  # writes off the test process, same reasoning as SimActivator's own
  # test file (see its own `use` line).
  use TradingOptionsSimWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.SimActivator

  defp fixed_leg_config do
    %{
      "expiry_selection" => "fixed",
      "fixed_expiry" => "20271231",
      "strike_selection" => "fixed_strike",
      "fixed_strike" => "150.00",
      "right" => "C"
    }
  end

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

  test "shows the live current price on a chip from a running monitor", %{conn: conn} do
    {:ok, strategy} = Sim.create_strategy(%{name: "Priced Strategy"})
    {:ok, pool} = Sim.create_target_pool(%{name: "Priced Pool"})
    {:ok, _member} = Sim.add_target_pool_member(pool, %{symbol: "PRICEDCHIP1"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1},
        target_pool_id: pool.id,
        option_leg_config: fixed_leg_config()
      })

    {:ok, [_pid], []} = SimActivator.activate(version)

    message =
      %{type: :price, symbol: "PRICEDCHIP1", source: :ibkr, data: %{last: 130.0}}
      |> Map.put(:__struct__, TradingHub.Message)

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:PRICEDCHIP1", message)
    Process.sleep(50)

    {:ok, _view, html} = live(conn, ~p"/active_strategies")

    assert html =~ "PRICEDCHIP1"
    refute html =~ ">—<"
  end

  test "deactivating a version stops it from showing on the page", %{conn: conn} do
    {:ok, strategy} = Sim.create_strategy(%{name: "Deactivate Me"})
    {:ok, pool} = Sim.create_target_pool(%{name: "Deactivate Pool"})

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

    {:ok, view, html} = live(conn, ~p"/active_strategies")
    assert html =~ "Deactivate Me"
    assert has_element?(view, "button[phx-click=deactivate][phx-value-id='#{version.id}']")

    html =
      view
      |> element("button[phx-click=deactivate][phx-value-id='#{version.id}']")
      |> render_click()

    refute html =~ "Deactivate Me"
    assert html =~ "No strategy versions currently have an open run"
    refute is_nil(Sim.get_strategy_version!(version.id).deactivated_at)
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
