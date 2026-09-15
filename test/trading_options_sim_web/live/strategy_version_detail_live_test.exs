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

  test "shows a copy-UUID button for the version's own id", %{conn: conn} do
    strategy = strategy_fixture()
    version = version_fixture(strategy)

    {:ok, view, _html} = live(conn, ~p"/strategy_versions/#{version.id}")

    assert has_element?(view, "button[data-copy-value='#{version.id}']")
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

  describe "recent fills panel" do
    test "hidden when no fills exist yet", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

      refute html =~ "Recent Fills"
    end

    test "shows entry and exit fills after a full trade cycle", %{conn: conn} do
      strategy = strategy_fixture()
      pool = pool_fixture("DETAILSYM6")

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
        %{type: :price, symbol: "DETAILSYM6", source: :ibkr, data: %{last: price}}
        |> Map.put(:__struct__, TradingHub.Message)
      end

      Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:DETAILSYM6", message.(130.0))
      Process.sleep(50)
      Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:DETAILSYM6", message.(150.0))
      Process.sleep(50)

      {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

      assert html =~ "Recent Fills"
      assert html =~ "DETAILSYM6"
      assert html =~ "entry"
      assert html =~ "exit"
    end
  end

  # Regression test for a real race: build_member_entry/4's "no open
  # run" branch is chosen based on a runs_by_symbol lookup taken before
  # ContractMonitor.snapshot/1 is called — an entry firing in between
  # those two reads used to render neither the "Flat" message nor the
  # position table (a blank gap, confirmed live 2026-09-15). Simulates
  # the race directly: an open run exists (a real entry happened), but
  # nothing pre-populates runs_by_symbol at load time is not something
  # this test can force via timing, so instead it asserts the actual
  # fallback path handles a live position_open? snapshot with no
  # pre-matched run by re-deriving it from the DB.
  test "shows position details (not a blank gap) for a member whose run wasn't pre-matched",
       %{conn: conn} do
    strategy = strategy_fixture()
    pool = pool_fixture("DETAILSYM7")

    version =
      version_fixture(strategy, %{
        target_pool_id: pool.id,
        option_leg_config: fixed_leg_config(),
        rules: %{"entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}}
      })

    {:ok, [_pid], []} = TradingOptionsSim.SimActivator.activate(version)

    message =
      %{type: :price, symbol: "DETAILSYM7", source: :ibkr, data: %{last: 150.0}}
      |> Map.put(:__struct__, TradingHub.Message)

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:DETAILSYM7", message)
    Process.sleep(50)

    {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

    refute html =~ "Flat — no open position"
    assert html =~ "Direction"
  end

  test "shows the live current price when position_open? but the SimRun genuinely isn't found",
       %{conn: conn} do
    # Confirmed live 2026-09-15: on a strategy whose entry/exit rules
    # sit close together on a fast-oscillating signal, an operator can
    # load the detail page during the brief real window a position is
    # open and see nothing but a vague "details refreshing…" — no
    # price, no direction, nothing actionable. Forces exactly that
    # state (position_open?: true, but the run this monitor is tracking
    # has been deleted out from under it) to assert the fallback now
    # shows at least the live current price and strategy direction
    # instead of leaving the operator with nothing to look at.
    strategy = strategy_fixture()
    pool = pool_fixture("DETAILSYM8")

    version =
      version_fixture(strategy, %{
        target_pool_id: pool.id,
        option_leg_config: fixed_leg_config(),
        rules: %{"entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}}
      })

    {:ok, [_pid], []} = TradingOptionsSim.SimActivator.activate(version)

    message =
      %{type: :price, symbol: "DETAILSYM8", source: :ibkr, data: %{last: 150.0}}
      |> Map.put(:__struct__, TradingHub.Message)

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:DETAILSYM8", message)
    Process.sleep(50)

    [run] = Sim.list_open_sim_runs(version)
    TradingOptionsSim.Repo.delete!(run)

    {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

    assert html =~ "Current"
    assert html =~ "150.0"
    assert html =~ "pending"
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

  describe "retire/unretire" do
    test "retiring shows the retired badge and swaps to an Unretire button", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      {:ok, view, _html} = live(conn, ~p"/strategy_versions/#{version.id}")
      assert has_element?(view, "button[phx-click=retire][phx-value-id='#{version.id}']")

      html =
        view
        |> element("button[phx-click=retire][phx-value-id='#{version.id}']")
        |> render_click()

      assert html =~ "retired"
      assert Sim.get_strategy_version!(version.id).lifecycle_stage == "retired"
      assert has_element?(view, "button[phx-click=unretire][phx-value-id='#{version.id}']")
    end

    test "unretiring puts the version back in discovery", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, version} = Sim.downgrade_strategy_version(version, "retired")

      {:ok, view, _html} = live(conn, ~p"/strategy_versions/#{version.id}")
      assert has_element?(view, "button[phx-click=unretire][phx-value-id='#{version.id}']")

      view
      |> element("button[phx-click=unretire][phx-value-id='#{version.id}']")
      |> render_click()

      assert Sim.get_strategy_version!(version.id).lifecycle_stage == "discovery"
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
