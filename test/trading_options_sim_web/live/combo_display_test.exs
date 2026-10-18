defmodule TradingOptionsSimWeb.ComboDisplayTest do
  use TradingOptionsSimWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TradingOptionsSim.Sim
  alias TradingOptionsSimWeb.StrategyVersionDetailLive, as: Detail

  @expiry "20271231"

  defp d(s), do: Decimal.new(s)

  defp legs do
    [
      %{leg_index: 0, right: "P", side: "short", strike: d("145"), expiry: @expiry, ratio: 1},
      %{leg_index: 1, right: "P", side: "long", strike: d("140"), expiry: @expiry, ratio: 1}
    ]
  end

  # An entered 145/140 put credit spread, recorded without a monitor.
  defp entered_combo do
    {:ok, strategy} = Sim.create_strategy(%{name: "Combo display"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        direction: "short",
        position_sizing: %{"method" => "fixed_qty", "qty" => 1},
        option_leg_config: %{
          "expiry_selection" => "fixed",
          "fixed_expiry" => @expiry,
          "multi_leg" => %{"structure" => "put_credit_spread", "short_offset" => 5, "width" => 5}
        },
        rules: %{"entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}},
        params: %{
          "risk_controls" => %{
            "method" => "percent_of_entry",
            "stop_loss_percent" => 100,
            "take_profit_percent" => 50
          }
        }
      })

    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: "CMBD",
        expiry: @expiry,
        strike: d("145"),
        right: "P",
        direction: "short",
        structure: "put_credit_spread"
      })

    now = DateTime.utc_now()

    fill = fn action, price, i ->
      %{
        action: action,
        quantity: 1,
        fill_price: d(price),
        filled_at: now,
        commission: d("0.65"),
        leg_index: i
      }
    end

    rows =
      Enum.map(
        legs(),
        &Map.put(&1, :entry_price, if(&1.side == "short", do: d("2"), else: d("1")))
      )

    {:ok, _} =
      Sim.record_combo_entry_fills(
        run,
        [fill.("sell", "2.00", 0), fill.("buy", "1.00", 1)],
        rows,
        %{
          entry_at: now,
          entry_price: d("1.00"),
          risk_at_entry: d("400"),
          context: %{"risk_basis" => "max_loss"}
        }
      )

    {version, run}
  end

  test "the version page lists each combo fill against its own leg", %{conn: conn} do
    {version, _run} = entered_combo()

    {:ok, _view, html} = live(conn, ~p"/strategy_versions/#{version.id}")

    assert html =~ "145P"
    assert html =~ "140P"
    assert html =~ "put credit spread leg 1"
    # Each leg's own OCC symbol, not the primary leg's twice.
    assert html =~ "CMBD  271231P00140000"
    assert html =~ "CMBD  271231P00145000"
  end

  test "the runs page shows every leg of a combo run", %{conn: conn} do
    _ = entered_combo()

    {:ok, _view, html} = live(conn, ~p"/runs")

    assert html =~ "-145P +140P put credit spread"
  end

  test "position_view/3 describes a combo's legs, net credit and max-loss capital" do
    snapshot = %{
      symbol: "CMBD",
      expiry: @expiry,
      strike: d("145"),
      right: "P",
      structure: "put_credit_spread",
      legs: legs(),
      entered_at: nil,
      min_hold_seconds: nil,
      last_snapshot: %{"run_current_price" => 0.5}
    }

    run = %{
      entry_price: d("1.00"),
      multiplier: 100,
      direction: "short",
      entry_at: nil,
      risk_at_entry: d("400")
    }

    v = Detail.position_view(run, snapshot, nil)

    assert v.contract == "#{@expiry} -145P +140P put credit spread"
    assert v.occ == nil
    assert v.cost_label == "Credit received"
    assert_in_delta v.capital, 400.0, 1.0e-9
    assert v.capital_basis == "max loss"
    # Short: the credit decaying from 1.00 to 0.50 is a +$50 gain.
    assert_in_delta v.unrealized, 50.0, 1.0e-6
  end
end
