defmodule TradingOptionsSimWeb.StrategyVersionDetailLiveTest do
  # async: false — activate/deactivate start/stop real ContractMonitor
  # processes under the shared TradingOptionsSim.MonitorRegistry/
  # MonitorSupervisor, same isolation concern SimActivatorTest's own
  # async: false already documents.
  use TradingOptionsSimWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TradingOptionsSim.Sim

  defp strategy_fixture do
    {:ok, strategy} = Sim.create_strategy(%{name: "Test Strategy"})
    strategy
  end

  defp pool_fixture(symbol) do
    {:ok, pool} = Sim.create_target_pool(%{name: "Pool #{System.unique_integer([:positive])}"})
    {:ok, _member} = Sim.add_target_pool_member(pool, %{symbol: symbol})
    Sim.get_target_pool!(pool.id)
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

  defp version_fixture(strategy, attrs \\ %{}) do
    {:ok, version} =
      Sim.create_strategy_version(
        strategy,
        Map.merge(
          %{
            version: 1,
            position_sizing: %{"method" => "fixed_qty", "qty" => 1},
            rules: %{
              "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
            }
          },
          attrs
        )
      )

    version
  end

  test "shows strategy name, version, and lifecycle badge", %{conn: conn} do
    strategy = strategy_fixture()
    version = version_fixture(strategy)

    {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

    assert html =~ "Test Strategy"
    assert html =~ "v1"
    assert html =~ "discovery"
  end

  test "shows the entry and exit rule JSON", %{conn: conn} do
    strategy = strategy_fixture()

    version =
      version_fixture(strategy, %{
        rules: %{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100},
          "exit" => %{"signal" => "run_underlying_price", "op" => "lt", "value" => 50}
        }
      })

    {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

    assert html =~ "run_underlying_price"
    assert html =~ "Entry Rule"
    assert html =~ "Exit Rule"
  end

  test "shows position sizing method and qty", %{conn: conn} do
    strategy = strategy_fixture()

    version =
      version_fixture(strategy, %{position_sizing: %{"method" => "fixed_qty", "qty" => 5}})

    {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

    assert html =~ "fixed_qty"
    assert html =~ "Position Sizing"
  end

  test "shows a message when no target pool is set", %{conn: conn} do
    strategy = strategy_fixture()
    version = version_fixture(strategy)

    {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

    assert html =~ "No target pool set"
  end

  test "lists target pool members as cards", %{conn: conn} do
    strategy = strategy_fixture()
    pool = pool_fixture("DETAILSYM1")
    version = version_fixture(strategy, %{target_pool_id: pool.id})

    {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

    assert html =~ "DETAILSYM1"
    assert html =~ "Not running"
  end

  describe "activate/deactivate" do
    test "activating starts a monitor and shows it as running", %{conn: conn} do
      strategy = strategy_fixture()
      pool = pool_fixture("DETAILSYM2")

      version =
        version_fixture(strategy, %{
          target_pool_id: pool.id,
          option_leg_config: fixed_leg_config()
        })

      {:ok, view, _html} = live(conn, ~p"/strategy_versions/#{version.id}")
      refute has_element?(view, "button[phx-click=deactivate]")

      html = view |> element("button[phx-click=activate]") |> render_click()

      assert html =~ "Running"
      assert has_element?(view, "button[phx-click=deactivate]")
      assert length(Sim.list_open_sim_runs(version)) == 1
    end

    test "still shows Running (flat) after a rule-triggered exit closes the run", %{conn: conn} do
      # Confirmed live 2026-09-15: before ContractMonitor's Registry key
      # was re-keyed to {strategy_version_id, contract_key}, this page
      # showed "Not running" for a monitor that was genuinely still
      # alive and watching — it had just entered and exited within
      # seconds on the same oscillating signal, and whereis/2 (keyed by
      # the now-closed run's own id) could no longer find it.
      strategy = strategy_fixture()
      pool = pool_fixture("DETAILSYM5")

      version =
        version_fixture(strategy, %{
          target_pool_id: pool.id,
          option_leg_config: fixed_leg_config(),
          rules: %{
            "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100},
            "exit" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 140}
          }
        })

      {:ok, [_pid], []} = TradingOptionsSim.SimActivator.activate(version)

      message = fn price ->
        %{type: :price, symbol: "DETAILSYM5", source: :ibkr, data: %{last: price}}
        |> Map.put(:__struct__, TradingHub.Message)
      end

      Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:DETAILSYM5", message.(130.0))
      Process.sleep(50)
      Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:DETAILSYM5", message.(150.0))
      Process.sleep(50)

      assert Sim.list_open_sim_runs(version) == []

      {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

      assert html =~ "Running"
      refute html =~ "No monitor running for this symbol"
      assert html =~ "Flat — no open position"
    end

    test "deactivating stops the monitor", %{conn: conn} do
      strategy = strategy_fixture()
      pool = pool_fixture("DETAILSYM3")

      version =
        version_fixture(strategy, %{
          target_pool_id: pool.id,
          option_leg_config: fixed_leg_config()
        })

      {:ok, _pids, []} = TradingOptionsSim.SimActivator.activate(version)

      {:ok, view, _html} = live(conn, ~p"/strategy_versions/#{version.id}")
      assert has_element?(view, "button[phx-click=deactivate]")

      html = view |> element("button[phx-click=deactivate]") |> render_click()

      assert html =~ "No monitor running" or html =~ "Not running"
      assert has_element?(view, "button[phx-click=activate]")
    end
  end

  describe "tags" do
    test "adding a tag shows the chip", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      {:ok, view, _html} = live(conn, ~p"/strategy_versions/#{version.id}")

      html =
        view
        |> form("form[phx-submit=add_tag]", %{"tag_name" => "hot"})
        |> render_submit()

      assert html =~ "hot"
    end

    test "removing a tag hides the chip", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, version} = Sim.add_tag_to_strategy_version_by_name(version, "hot")
      tag = hd(version.tags)

      {:ok, view, html} = live(conn, ~p"/strategy_versions/#{version.id}")
      assert html =~ "hot"

      html =
        view
        |> element("button[phx-click=remove_tag][phx-value-tag_id='#{tag.id}']")
        |> render_click()

      refute html =~ "hot"
    end
  end

  describe "notes" do
    test "shows the Add Notes button when no notes exist", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

      assert html =~ "Add Notes"
    end

    test "saving notes shows them and hides the edit form", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      {:ok, view, _html} = live(conn, ~p"/strategy_versions/#{version.id}")

      view |> element("button[phx-click=edit_notes]") |> render_click()

      html =
        view
        |> form("form[phx-submit=save_notes]", %{"notes" => "Some thesis"})
        |> render_submit()

      assert html =~ "Some thesis"
      refute has_element?(view, "form[phx-submit=save_notes]")
    end
  end
end
