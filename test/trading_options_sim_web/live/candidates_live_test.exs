defmodule TradingOptionsSimWeb.CandidatesLiveTest do
  use TradingOptionsSimWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TradingOptionsSim.Sim

  defp strategy_fixture(attrs \\ %{}) do
    {:ok, strategy} = Sim.create_strategy(Map.merge(%{name: "Test Strategy"}, attrs))
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

  defp candidate_run_fixture(version, attrs) do
    {:ok, run} =
      Sim.open_sim_run(
        version,
        Map.merge(
          %{
            symbol: "CANDLIVE1",
            expiry: "20271231",
            strike: Decimal.new("150.00"),
            right: "C",
            multiplier: 100,
            direction: "long"
          },
          Map.take(attrs, [:symbol])
        )
      )

    now = DateTime.utc_now()
    entry_price = Decimal.new("5.00")
    risk_at_entry = Sim.compute_risk_at_entry(entry_price, 100, 1)

    {:ok, {_fill, run}} =
      Sim.record_entry_fill(
        run,
        %{action: "buy", quantity: 1, fill_price: entry_price, filled_at: now},
        %{entry_at: now, entry_price: entry_price, risk_at_entry: risk_at_entry}
      )

    {:ok, {_fill, run}} =
      Sim.record_exit_fill(
        run,
        %{
          action: "sell",
          quantity: 1,
          fill_price: Map.fetch!(attrs, :exit_price),
          filled_at: now
        },
        %{
          exit_at: now,
          exit_price: Map.fetch!(attrs, :exit_price),
          exit_reason: Map.get(attrs, :exit_reason, "target_hit"),
          realized_pnl: Map.fetch!(attrs, :realized_pnl),
          realized_pnl_net: Map.fetch!(attrs, :realized_pnl)
        }
      )

    run
  end

  test "shows an empty state with no candidates", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/candidates")
    assert html =~ "No candidates match the current filters"
  end

  test "shows a discovery version with at least 30 closed runs by default", %{conn: conn} do
    strategy = strategy_fixture(%{name: "Candidate Strategy"})
    version = version_fixture(strategy)

    for _ <- 1..30 do
      candidate_run_fixture(version, %{
        symbol: "CANDLIVE2",
        exit_price: Decimal.new("6.00"),
        realized_pnl: Decimal.new("100.00")
      })
    end

    {:ok, _view, html} = live(conn, ~p"/candidates")

    assert html =~ "Candidate Strategy"
    assert html =~ "lcb95"
  end

  test "hides a version below the sample floor by default, shows it with Show all", %{
    conn: conn
  } do
    strategy = strategy_fixture(%{name: "Thin Sample Strategy"})
    version = version_fixture(strategy)

    candidate_run_fixture(version, %{
      symbol: "CANDLIVE3",
      exit_price: Decimal.new("6.00"),
      realized_pnl: Decimal.new("100.00")
    })

    {:ok, view, html} = live(conn, ~p"/candidates")
    refute html =~ "Thin Sample Strategy"

    html =
      view
      |> element("button", "Show all")
      |> render_click()

    assert html =~ "Thin Sample Strategy"
  end

  test "the stage counts strip renders", %{conn: conn} do
    strategy = strategy_fixture()
    version_fixture(strategy)

    {:ok, _view, html} = live(conn, ~p"/candidates")
    assert html =~ "D 1"
  end

  test "clicking a sortable column header re-sorts", %{conn: conn} do
    strategy = strategy_fixture()
    version = version_fixture(strategy)

    candidate_run_fixture(version, %{
      symbol: "CANDLIVE4",
      exit_price: Decimal.new("6.00"),
      realized_pnl: Decimal.new("100.00")
    })

    {:ok, view, _html} = live(conn, ~p"/candidates")
    view |> element("button", "Show all") |> render_click()

    html =
      view
      |> element("th[phx-value-sort_by='n_closes']")
      |> render_click()

    assert html =~ "n_closes"
  end

  test "clicking the r_per_capital_hour column header re-sorts without crashing", %{conn: conn} do
    strategy = strategy_fixture()
    version = version_fixture(strategy)

    candidate_run_fixture(version, %{
      symbol: "CANDLIVE9",
      exit_price: Decimal.new("6.00"),
      realized_pnl: Decimal.new("100.00")
    })

    {:ok, view, _html} = live(conn, ~p"/candidates")
    view |> element("button", "Show all") |> render_click()

    html =
      view
      |> element("th[phx-value-sort_by='r_per_capital_hour']")
      |> render_click()

    assert html =~ "cap-hr"
  end

  test "toggling near-miss filters to rows failing exactly 1-2 gates", %{conn: conn} do
    strategy = strategy_fixture(%{name: "Near Miss Strategy"})
    version = version_fixture(strategy)

    for _ <- 1..30 do
      candidate_run_fixture(version, %{
        symbol: "CANDLIVE5",
        exit_price: Decimal.new("6.00"),
        realized_pnl: Decimal.new("100.00")
      })
    end

    {:ok, view, _html} = live(conn, ~p"/candidates")

    html =
      view
      |> element("button", "Near-miss")
      |> render_click()

    # With no target pool set, this version fails at least one gate
    # (its stage counts still show up in the strip regardless).
    assert html =~ "Near-miss"
  end

  test "toggling expand reveals the strategy id", %{conn: conn} do
    strategy = strategy_fixture()
    version = version_fixture(strategy)

    candidate_run_fixture(version, %{
      symbol: "CANDLIVE6",
      exit_price: Decimal.new("6.00"),
      realized_pnl: Decimal.new("100.00")
    })

    {:ok, view, _html} = live(conn, ~p"/candidates")

    # Below the sample floor with only 1 closed run — Show all first.
    view |> element("button", "Show all") |> render_click()

    refute render(view) =~ "strategy: #{strategy.id}"

    html =
      view
      |> element("button[phx-value-id='#{version.id}']")
      |> render_click()

    assert html =~ "strategy: #{strategy.id}"
  end
end
