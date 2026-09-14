defmodule TradingOptionsSimWeb.StrategyVersionsLiveActivationTest do
  # async: false — activate/deactivate start/stop real ContractMonitor
  # processes under the shared TradingOptionsSim.MonitorRegistry/
  # MonitorSupervisor, same isolation concern SimActivatorTest's own
  # async: false already documents.
  use TradingOptionsSimWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TradingOptionsSim.Sim

  defp pool_fixture(symbol) do
    {:ok, pool} = Sim.create_target_pool(%{name: "Pool #{System.unique_integer([:positive])}"})
    {:ok, _member} = Sim.add_target_pool_member(pool, %{symbol: symbol})
    Sim.get_target_pool!(pool.id)
  end

  defp version_fixture(attrs \\ %{}) do
    {:ok, strategy} = Sim.create_strategy(%{name: "Test Strategy"})

    {:ok, version} =
      Sim.create_strategy_version(
        strategy,
        Map.merge(%{version: 1, position_sizing: %{"method" => "fixed_qty", "qty" => 1}}, attrs)
      )

    version
  end

  defp fixed_leg_config do
    %{
      "expiry_selection" => "fixed",
      "fixed_expiry" => "20271231",
      "strike_selection" => "fixed_strike",
      "fixed_strike" => "150.00",
      "right" => "C"
    }
  end

  test "activating a discovery version with a target pool starts monitors", %{conn: conn} do
    pool = pool_fixture("ACTLIVE1")
    version = version_fixture(%{target_pool_id: pool.id, option_leg_config: fixed_leg_config()})

    {:ok, view, _html} = live(conn, ~p"/strategy_versions")
    refute has_element?(view, "button[phx-click=deactivate][phx-value-id='#{version.id}']")

    render_click(view, "activate", %{"id" => version.id})

    assert has_element?(view, "button[phx-click=deactivate][phx-value-id='#{version.id}']")
    assert length(Sim.list_open_sim_runs(version)) == 1
  end

  test "activating a version with no target pool shows an error flash", %{conn: conn} do
    version = version_fixture()

    {:ok, view, _html} = live(conn, ~p"/strategy_versions")

    html =
      view
      |> element("button[phx-click=activate][phx-value-id='#{version.id}']")
      |> render_click()

    assert html =~ "no target pool"
  end

  test "deactivating a running version stops its monitors", %{conn: conn} do
    pool = pool_fixture("ACTLIVE2")
    version = version_fixture(%{target_pool_id: pool.id, option_leg_config: fixed_leg_config()})

    {:ok, pids, []} = TradingOptionsSim.SimActivator.activate(version)
    assert Enum.all?(pids, &Process.alive?/1)

    {:ok, view, _html} = live(conn, ~p"/strategy_versions")
    assert has_element?(view, "button[phx-click=deactivate][phx-value-id='#{version.id}']")

    render_click(view, "deactivate", %{"id" => version.id})

    refute has_element?(view, "button[phx-click=deactivate][phx-value-id='#{version.id}']")
    assert has_element?(view, "button[phx-click=activate][phx-value-id='#{version.id}']")

    Process.sleep(20)
    refute Enum.any?(pids, &Process.alive?/1)
  end
end
