defmodule TradingOptionsSimWeb.ActiveStrategiesLiveTest do
  # async: false — several tests start a real ContractMonitor (via
  # SimActivator.activate/1) that does its own DB writes off the test
  # process, same reasoning as SimActivator's own test file (see its
  # own `use` line).
  use TradingOptionsSimWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Repo
  alias TradingOptionsSim.Sim.StrategyVersion
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

  defp activated_version_fixture(strategy_name, symbols, attrs \\ %{}) do
    {:ok, strategy} = Sim.create_strategy(%{name: strategy_name})
    {:ok, pool} = Sim.create_target_pool(%{name: "#{strategy_name} Pool"})
    Enum.each(symbols, fn symbol -> Sim.add_target_pool_member(pool, %{symbol: symbol}) end)

    {:ok, version} =
      Sim.create_strategy_version(
        strategy,
        Map.merge(
          %{
            version: 1,
            position_sizing: %{"method" => "fixed_qty", "qty" => 1},
            target_pool_id: pool.id,
            option_leg_config: fixed_leg_config()
          },
          attrs
        )
      )

    {:ok, [_pid], []} = SimActivator.activate(version)
    Sim.get_strategy_version!(version.id)
  end

  test "shows an empty state with no active versions", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/active_strategies")
    assert html =~ "No strategy versions are currently active"
  end

  test "shows a chip per target-pool member for an active version", %{conn: conn} do
    activated_version_fixture("Test Strategy", ["AAPL"])

    {:ok, _view, html} = live(conn, ~p"/active_strategies")

    assert html =~ "Test Strategy"
    assert html =~ "AAPL"
  end

  test "a member with no open position shows Flat", %{conn: conn} do
    activated_version_fixture("Flat Strategy", ["FLATCHIP1"])

    {:ok, _view, html} = live(conn, ~p"/active_strategies")

    assert html =~ "FLATCHIP1"
    assert html =~ "Flat"
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
    assert html =~ "No strategy versions are currently active"
  end

  test "shows an open position's direction and entry price instead of Flat", %{conn: conn} do
    activated_version_fixture("Positioned Strategy", ["POSCHIP1"])

    message =
      %{type: :price, symbol: "POSCHIP1", source: :ibkr, data: %{last: 130.0}}
      |> Map.put(:__struct__, TradingHub.Message)

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:POSCHIP1", message)
    Process.sleep(50)

    {:ok, _view, html} = live(conn, ~p"/active_strategies")

    assert html =~ "POSCHIP1"
    assert html =~ "Position: Long"
    assert html =~ "Entry"
    refute html =~ "Flat"
  end

  test "shows Last exit after a closed trade, with no open position", %{conn: conn} do
    version = activated_version_fixture("Exited Strategy", ["EXITCHIP1"])

    message = fn price ->
      %{type: :price, symbol: "EXITCHIP1", source: :ibkr, data: %{last: price}}
      |> Map.put(:__struct__, TradingHub.Message)
    end

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:EXITCHIP1", message.(150.0))
    Process.sleep(50)

    # This version's default rules are empty (vacuously true) so any
    # tick enters; force a real exit via deactivate isn't right (it
    # would flatten via force_close, not a rule exit) — instead close
    # the run directly through the same Sim functions ContractMonitor
    # itself uses, matching the "exit fires on a genuinely different
    # tick" real flow closely enough for a chip-display test.
    [run] = Sim.list_open_sim_runs(version)
    now = DateTime.utc_now()

    {:ok, {_fill, _run}} =
      Sim.record_exit_fill(
        run,
        %{action: "sell", quantity: 1, fill_price: Decimal.new("145.00"), filled_at: now},
        %{
          exit_at: now,
          exit_price: Decimal.new("145.00"),
          exit_reason: "manual",
          realized_pnl: Decimal.new("-50.00")
        }
      )

    {:ok, _view, html} = live(conn, ~p"/active_strategies")

    assert html =~ "EXITCHIP1"
    assert html =~ "Last exit"
    assert html =~ "Flat"
  end

  test "deactivating a version stops it from showing on the page", %{conn: conn} do
    version = activated_version_fixture("Deactivate Me", ["DEACTCHIP1"])

    {:ok, view, html} = live(conn, ~p"/active_strategies")
    assert html =~ "Deactivate Me"
    assert has_element?(view, "button[phx-click=deactivate][phx-value-id='#{version.id}']")

    html =
      view
      |> element("button[phx-click=deactivate][phx-value-id='#{version.id}']")
      |> render_click()

    refute html =~ "Deactivate Me"
    assert html =~ "No strategy versions are currently active"
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

  # So the TP-SL improved / TPSL-none groups (and any other tag) are
  # visible where the running strategies are listed.
  test "shows each active version's tags", %{conn: conn} do
    {:ok, strategy} = TradingOptionsSim.Sim.create_strategy(%{name: "Tagged Active"})

    {:ok, v} =
      TradingOptionsSim.Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    {:ok, v} = TradingOptionsSim.Sim.mark_activated(v)
    {:ok, _} = TradingOptionsSim.Sim.add_tag_to_strategy_version_by_name(v, "TP-SL improved")

    {:ok, other} = TradingOptionsSim.Sim.create_strategy(%{name: "Untagged Active"})

    {:ok, u} =
      TradingOptionsSim.Sim.create_strategy_version(other, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    {:ok, _} = TradingOptionsSim.Sim.mark_activated(u)

    {:ok, _view, html} = live(conn, ~p"/active_strategies")

    assert html =~ "Tagged Active"
    assert html =~ "TP-SL improved"
    assert html =~ "Untagged Active"
  end

  describe "stage filter pills" do
    defp set_stage(version, stage) do
      version
      |> StrategyVersion.lifecycle_stage_changeset(%{lifecycle_stage: stage})
      |> Repo.update!()
    end

    setup do
      activated_version_fixture("Disco Pill Strategy", ["DPILL"])
      "Quar Pill Strategy" |> activated_version_fixture(["QPILL"]) |> set_stage("quarantine")
      "Test Pill Strategy" |> activated_version_fixture(["TPILL"]) |> set_stage("test_portfolio")
      :ok
    end

    test "All shows every stage, with per-stage counts of active versions", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/active_strategies")

      assert html =~ "Disco Pill Strategy"
      assert html =~ "Quar Pill Strategy"
      assert html =~ "Test Pill Strategy"
      assert has_element?(view, "a[href='/active_strategies']", ~r/All\s+3/)

      assert has_element?(
               view,
               "a[href='/active_strategies?stage=quarantine']",
               ~r/Quarantine\s+1/
             )
    end

    test "a stage pill shows only that stage", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/active_strategies?stage=quarantine")

      assert html =~ "Quar Pill Strategy"
      refute html =~ "Disco Pill Strategy"
      refute html =~ "Test Pill Strategy"
    end

    test "clicking a pill patches the URL and filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/active_strategies")

      html = view |> element("a", "Test Portfolio") |> render_click()
      assert_patch(view, ~p"/active_strategies?stage=test_portfolio")
      assert html =~ "Test Pill Strategy"
      refute html =~ "Disco Pill Strategy"
    end

    test "an unknown stage param falls back to All", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/active_strategies?stage=bogus")

      assert html =~ "Disco Pill Strategy"
      assert html =~ "Quar Pill Strategy"
    end

    test "the stage filter combines with search", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/active_strategies?stage=discovery")

      html = view |> form("form[phx-change=search]", %{q: "quar"}) |> render_change()
      assert html =~ "No active strategy versions match this filter"
    end
  end
end
