defmodule TradingOptionsSimWeb.StrategyVersionDetailLiveTest do
  # async: false — activate/deactivate start/stop real ContractMonitor
  # processes under the shared TradingOptionsSim.MonitorRegistry/
  # MonitorSupervisor, same isolation concern SimActivatorTest's own
  # async: false already documents.
  use TradingOptionsSimWeb.ConnCase, async: false

  # Deterministic replacement for Process.sleep/1 after a broadcast.
  # PubSub delivery is asynchronous, so sleeping is a bet that the
  # monitor finishes inside the interval -- usually safe, occasionally
  # not, and the failures look like unrelated cross-test interference.
  # A GenServer.call cannot be served until the monitor has drained the
  # broadcast ahead of it, so this returns exactly when the work is
  # done. See contract_monitor_test.exs's own sync/1 for the same fix.
  defp sync_monitor(pid) do
    _ = TradingOptionsSim.ContractMonitor.snapshot(pid)
    :ok
  end

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

  describe "position_view/3" do
    alias TradingOptionsSimWeb.StrategyVersionDetailLive, as: Detail

    defp snap(values, opts \\ []) do
      %{
        symbol: "SPY",
        expiry: "20261120",
        strike: Decimal.new("770.00"),
        right: "C",
        entered_at: Keyword.get(opts, :entered_at),
        min_hold_seconds: Keyword.get(opts, :min_hold),
        last_snapshot: values
      }
    end

    defp open_run(direction \\ "long"),
      do: %{
        entry_price: Decimal.new("10.00"),
        multiplier: 100,
        direction: direction,
        entry_at: nil
      }

    test "marks at the quote mid when a two-sided book exists" do
      v =
        Detail.position_view(
          open_run(),
          snap(%{"run_bid" => 11.0, "run_ask" => 11.2, "run_current_price" => 99.0}),
          nil
        )

      assert v.mark_basis == "quote mid"
      assert_in_delta v.mark, 11.1, 1.0e-9
      assert_in_delta v.unrealized, 110.0, 1.0e-6
      assert_in_delta v.unrealized_pct, 11.0, 1.0e-6
      assert v.occ == "SPY   261120C00770000"
    end

    test "falls back to the model price, labelled, with no book" do
      v = Detail.position_view(open_run(), snap(%{"run_current_price" => 9.0}), nil)

      assert v.mark_basis == "model"
      assert_in_delta v.unrealized, -100.0, 1.0e-6
    end

    test "a short profits when the mark falls" do
      v = Detail.position_view(open_run("short"), snap(%{"run_current_price" => 9.0}), nil)
      assert_in_delta v.unrealized, 100.0, 1.0e-6
    end

    test "no price at all means no P&L rather than a made-up one" do
      v = Detail.position_view(open_run(), snap(%{}), nil)
      assert v.mark == nil
      assert v.unrealized == nil
    end

    test "reports time held and the min-hold still remaining" do
      entered = DateTime.add(DateTime.utc_now(), -600, :second)
      v = Detail.position_view(open_run(), snap(%{}, entered_at: entered, min_hold: 1800), nil)

      assert v.held_minutes == 10
      assert_in_delta v.hold_remaining_seconds, 1200, 2
    end
  end

  # Before 2026-09-24 the page rebuilt the monitor's key from the leg
  # config, so any monitor on a strike the config didn't name (every
  # atm_offset version, and any resumed run) showed "Not running".
  test "a monitor on a strike the leg config doesn't name shows Running with its position",
       %{conn: conn} do
    strategy = strategy_fixture()
    pool = pool_fixture("DTRES1")

    version =
      version_fixture(strategy, %{
        target_pool_id: pool.id,
        option_leg_config: fixed_leg_config(),
        # A nil exit rule is vacuously TRUE and would exit on the first
        # tick; this one never fires, so the position stays open.
        rules: %{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 0},
          "exit" => %{"signal" => "run_underlying_price", "op" => "lt", "value" => 0}
        }
      })

    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: "DTRES1",
        expiry: "20271231",
        strike: Decimal.new("145.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

    at = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, {_fill, _run}} =
      Sim.record_entry_fill(
        run,
        %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: at},
        %{entry_at: at, entry_price: Decimal.new("5.00")}
      )

    {:ok, [pid], []} = TradingOptionsSim.SimActivator.activate(version)

    message =
      %{type: :price, symbol: "DTRES1", source: :ibkr, data: %{last: 150.0}}
      |> Map.put(:__struct__, TradingHub.Message)

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:DTRES1", message)
    sync_monitor(pid)

    {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

    assert html =~ "Running"
    refute html =~ "Not running"
    assert html =~ "DTRES1271231C00145000"
    assert html =~ ~r/\$5\.00\s*×\s*1/
    assert html =~ "Mark"
    # $5.00/share x 100 x 1: paid in full up front, so also the capital.
    assert html =~ "Cost to buy"
    assert html =~ "$500.00"
    assert html =~ "capital at risk"
    assert html =~ "Capital in use:"
  end

  # Found in review: a closed run with an exit but no entry price (bad or
  # excluded data) must render, not crash the page.
  test "a closed run with no entry price still renders", %{conn: conn} do
    strategy = strategy_fixture()
    pool = pool_fixture("DETAILCOST2")

    version =
      version_fixture(strategy, %{target_pool_id: pool.id, option_leg_config: fixed_leg_config()})

    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: "DETAILCOST2",
        expiry: "20271231",
        strike: Decimal.new("150.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

    run
    |> Ecto.Changeset.change(
      status: "closed",
      exit_at: DateTime.utc_now(),
      exit_price: Decimal.new("6.00"),
      exit_reason: "rule_exit"
    )
    |> TradingOptionsSim.Repo.update!()

    {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

    assert html =~ "Last closed:"
    assert html =~ "$6.00"
  end

  # The dollar round trip a person repricing the trade by hand would
  # produce -- the per-share quote alone hides that a contract is 100
  # shares.
  test "the last closed trade shows cost, proceeds, fees, net and return", %{conn: conn} do
    strategy = strategy_fixture()
    pool = pool_fixture("DETAILCOST1")

    version =
      version_fixture(strategy, %{target_pool_id: pool.id, option_leg_config: fixed_leg_config()})

    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: "DETAILCOST1",
        expiry: "20271231",
        strike: Decimal.new("150.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

    entry_at = ~U[2026-09-24 18:03:00Z]
    exit_at = ~U[2026-09-24 18:25:00Z]

    {:ok, {_fill, run}} =
      Sim.record_entry_fill(
        run,
        %{
          action: "buy",
          quantity: 1,
          fill_price: Decimal.new("28.36"),
          filled_at: entry_at,
          commission: Decimal.new("1.05")
        },
        %{entry_at: entry_at, entry_price: Decimal.new("28.36")}
      )

    {:ok, {_fill, _run}} =
      Sim.record_exit_fill(
        run,
        %{
          action: "sell",
          quantity: 1,
          fill_price: Decimal.new("29.41"),
          filled_at: exit_at,
          commission: Decimal.new("1.06")
        },
        %{
          exit_at: exit_at,
          exit_price: Decimal.new("29.41"),
          exit_reason: "rule_exit",
          realized_pnl: Decimal.new("105.00"),
          realized_pnl_net: Decimal.new("102.89")
        }
      )

    {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

    assert html =~ "$2836.00"
    assert html =~ "$2941.00"
    assert html =~ "+$105.00"
    assert html =~ "$2.11"
    assert html =~ "+$102.89"
    assert html =~ "3.6% on capital"
    assert html =~ "22 min"
    # Recent Fills value column: 28.36 x 100 x 1
    assert html =~ ">Value<"
  end

  describe "promote button" do
    test "walks discovery -> quarantine -> test_portfolio, one valid step at a time", %{
      conn: conn
    } do
      strategy = strategy_fixture()
      pool = pool_fixture("PROMO1")
      version = version_fixture(strategy, %{target_pool_id: pool.id})

      {:ok, view, _html} = live(conn, ~p"/strategy_versions/#{version.id}")
      assert has_element?(view, "#promote-button", "Promote to quarantine")

      view |> element("#promote-button") |> render_click()
      assert Sim.get_strategy_version!(version.id).lifecycle_stage == "quarantine"
      assert has_element?(view, "#promote-button", "Promote to test_portfolio")

      view |> element("#promote-button") |> render_click()
      assert Sim.get_strategy_version!(version.id).lifecycle_stage == "test_portfolio"

      # test_portfolio is the last stage here; going live is a trading_live link.
      refute has_element?(view, "#promote-button")
    end

    test "a discovery version without a target pool gets a hint, not a button", %{conn: conn} do
      version = version_fixture(strategy_fixture())

      {:ok, view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

      refute has_element?(view, "#promote-button")
      assert html =~ "Set a target pool to promote"
    end

    test "a retired version has no promote button (only Unretire)", %{conn: conn} do
      version = version_fixture(strategy_fixture())
      {:ok, retired} = Sim.downgrade_strategy_version(version, "retired")

      {:ok, view, _html} = live(conn, ~p"/strategy_versions/#{retired.id}")

      refute has_element?(view, "#promote-button")
    end
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

      {:ok, [pid], []} = TradingOptionsSim.SimActivator.activate(version)

      message = fn price ->
        %{type: :price, symbol: "DETAILSYM6", source: :ibkr, data: %{last: price}}
        |> Map.put(:__struct__, TradingHub.Message)
      end

      Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:DETAILSYM6", message.(130.0))
      sync_monitor(pid)
      Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:DETAILSYM6", message.(150.0))
      sync_monitor(pid)

      {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

      assert html =~ "Recent Fills"
      assert html =~ "DETAILSYM6"
      assert html =~ "entry"
      assert html =~ "exit"
      # Two fills (one entry, one exit) from the single trade cycle above.
      assert html =~ "2 of 2"
    end

    test "shows the total fill count separately from the displayed (limit-15) list", %{
      conn: conn
    } do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      {:ok, run} =
        TradingOptionsSim.Sim.open_sim_run(version, %{
          symbol: "DETAILSYM7",
          expiry: "20271231",
          strike: Decimal.new("150.00"),
          right: "C",
          multiplier: 100,
          direction: "long"
        })

      now = DateTime.utc_now()

      {:ok, {_fill, run}} =
        TradingOptionsSim.Sim.record_entry_fill(
          run,
          %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: now},
          %{entry_at: now, entry_price: Decimal.new("5.00")}
        )

      {:ok, {_fill, _run}} =
        TradingOptionsSim.Sim.record_exit_fill(
          run,
          %{action: "sell", quantity: 1, fill_price: Decimal.new("6.00"), filled_at: now},
          %{
            exit_at: now,
            exit_price: Decimal.new("6.00"),
            exit_reason: "target_hit",
            realized_pnl: Decimal.new("100.00")
          }
        )

      assert TradingOptionsSim.Sim.count_fills_for_version(version) == 2

      {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

      assert html =~ "2 of 2"
    end

    # For looking the contract up in IBKR. The padding spaces are part of
    # the symbol, so they must survive rendering intact.
    test "shows each fill's OCC symbol with its padding intact", %{conn: conn} do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      now = DateTime.utc_now()

      {:ok, run} =
        TradingOptionsSim.Sim.open_sim_run(version, %{
          symbol: "TLT",
          expiry: "20261120",
          strike: Decimal.new("80.00"),
          right: "P",
          multiplier: 100,
          direction: "long"
        })

      {:ok, {_fill, _run}} =
        TradingOptionsSim.Sim.record_entry_fill(
          run,
          %{action: "buy", quantity: 1, fill_price: Decimal.new("1.80"), filled_at: now},
          %{entry_at: now, entry_price: Decimal.new("1.80")}
        )

      {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

      assert html =~ ">OCC<"
      # Nothing but the symbol inside the selectable span: no template
      # whitespace for select-all to copy along with it.
      assert html =~ ">TLT   261120P00080000</span>"
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

    {:ok, [pid], []} = TradingOptionsSim.SimActivator.activate(version)

    message =
      %{type: :price, symbol: "DETAILSYM7", source: :ibkr, data: %{last: 150.0}}
      |> Map.put(:__struct__, TradingHub.Message)

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:DETAILSYM7", message)
    sync_monitor(pid)

    {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

    refute html =~ "Flat — watching this contract"
    assert html =~ "Mark"
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

    {:ok, [pid], []} = TradingOptionsSim.SimActivator.activate(version)

    message =
      %{type: :price, symbol: "DETAILSYM8", source: :ibkr, data: %{last: 150.0}}
      |> Map.put(:__struct__, TradingHub.Message)

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:DETAILSYM8", message)
    sync_monitor(pid)

    [run] = Sim.list_open_sim_runs(version)
    TradingOptionsSim.Repo.delete!(run)

    {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

    assert html =~ "Mark"
    assert html =~ "150.0"
    assert html =~ "pending"
  end

  test "does not crash when position_open? but the SimRun's own entry_price is still nil", %{
    conn: conn
  } do
    # Confirmed live 2026-09-15: FunctionClauseError in Decimal.decimal/1
    # (called from Decimal.round/2) at
    # GET /strategy_versions/:id — @entry.run existed (a real open
    # SimRun row, status "open") but its entry_price was still nil, a
    # real state open_sim_run/2 leaves a run in until
    # record_entry_fill/3's own transaction commits both the entry fill
    # and entry_price together. The Entry row's own guard was
    # `:if={@entry.run}` — true here despite entry_price being nil, so
    # `Decimal.round(@entry.run.entry_price, 2)` crashed on nil rather
    # than falling back to the same "Current price / pending" display
    # the is_nil(@entry.run) case already handles below.
    strategy = strategy_fixture()
    pool = pool_fixture("DETAILSYM9")

    version =
      version_fixture(strategy, %{
        target_pool_id: pool.id,
        option_leg_config: fixed_leg_config(),
        rules: %{"entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}}
      })

    {:ok, [pid], []} = TradingOptionsSim.SimActivator.activate(version)

    message =
      %{type: :price, symbol: "DETAILSYM9", source: :ibkr, data: %{last: 150.0}}
      |> Map.put(:__struct__, TradingHub.Message)

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:DETAILSYM9", message)
    sync_monitor(pid)

    [run] = Sim.list_open_sim_runs(version)
    refute is_nil(run.entry_price)

    {:ok, _run} =
      run
      |> Ecto.Changeset.change(entry_price: nil)
      |> TradingOptionsSim.Repo.update()

    {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

    assert html =~ "Mark"
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

      {:ok, [pid], []} = TradingOptionsSim.SimActivator.activate(version)

      message = fn price ->
        %{type: :price, symbol: "DETAILSYM5", source: :ibkr, data: %{last: price}}
        |> Map.put(:__struct__, TradingHub.Message)
      end

      Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:DETAILSYM5", message.(130.0))
      sync_monitor(pid)
      Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:DETAILSYM5", message.(150.0))
      sync_monitor(pid)

      assert Sim.list_open_sim_runs(version) == []

      {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

      assert html =~ "Running"
      refute html =~ "No monitor running for this symbol"
      assert html =~ "Flat — watching this contract"
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

  describe "data_ages/2" do
    alias TradingOptionsSimWeb.StrategyVersionDetailLive, as: Detail

    @now ~U[2026-09-25 17:00:00Z]

    test "reports each age in seconds and flags ones past the staleness limit" do
      snap = %{
        evaluated_at: DateTime.add(@now, -3, :second),
        option_tick_at: DateTime.add(@now, -45, :second),
        quote_at: DateTime.add(@now, -90, :second),
        max_tick_age_ms: 60_000
      }

      assert [
               %{label: "Evaluated", age_s: 3, stale?: false},
               %{label: "Option tick", age_s: 45, stale?: false},
               %{label: "Quote", age_s: 90, stale?: true}
             ] = Detail.data_ages(snap, @now)
    end

    test "a monitor with no IBKR data shows only Evaluated, as never" do
      snap = %{evaluated_at: nil, option_tick_at: nil, quote_at: nil, max_tick_age_ms: 60_000}
      assert [%{label: "Evaluated", age_s: nil, stale?: false}] = Detail.data_ages(snap, @now)
    end
  end
end
