defmodule TradingOptionsSim.Sim.TradeCostTest do
  use ExUnit.Case, async: true

  alias TradingOptionsSim.Sim.{SimFill, SimRun, TradeCost}

  defp d(s), do: Decimal.new(s)

  defp fill(kind, price, commission, slippage \\ nil) do
    %SimFill{
      kind: kind,
      quantity: 1,
      fill_price: d(price),
      commission: commission && d(commission),
      pricing_snapshot:
        if(slippage,
          do: %{"fill_basis" => "quote", "fill_slippage" => slippage},
          else: %{"fill_basis" => "model_price", "fill_slippage" => "0"}
        )
    }
  end

  # The real QQQ round trip for VWAP Spread Reversion Call on
  # 2026-09-24, as repriced by hand: $28.36 -> $29.41, 1 contract.
  defp qqq_run(direction \\ "long") do
    %SimRun{
      direction: direction,
      multiplier: 100,
      entry_price: d("28.36"),
      exit_price: d("29.41"),
      realized_pnl: d("105.00"),
      realized_pnl_net: d("102.89"),
      entry_at: ~U[2026-09-24 18:03:00Z],
      exit_at: ~U[2026-09-24 18:25:00Z]
    }
  end

  test "prices a long round trip the way a person would by hand" do
    s =
      TradeCost.summary(qqq_run(), [
        fill("entry", "28.36", "1.05", "0.025"),
        fill("exit", "29.41", "1.06", "0.025")
      ])

    assert s.contracts == 1
    assert Decimal.equal?(s.cost_to_buy, d("2836.00"))
    assert Decimal.equal?(s.proceeds, d("2941.00"))
    assert Decimal.equal?(s.capital, d("2836.00"))
    assert Decimal.equal?(s.gross_pnl, d("105.00"))
    assert Decimal.equal?(s.fees, d("2.11"))
    assert Decimal.equal?(s.net_pnl, d("102.89"))
    assert Decimal.equal?(s.return_pct, d("3.6"))
    assert Decimal.equal?(s.spread_paid, d("5.00"))
    assert s.hold_minutes == 22
  end

  test "scales by contracts" do
    fills = [%{fill("entry", "28.36", "2.10") | quantity: 3}]

    s =
      TradeCost.summary(
        %{qqq_run() | exit_price: nil, realized_pnl: nil, realized_pnl_net: nil},
        fills
      )

    assert s.contracts == 3
    assert Decimal.equal?(s.cost_to_buy, d("8508.00"))
    assert s.proceeds == nil
    assert s.net_pnl == nil
  end

  # A short entered before its margin was recorded has the premium in
  # risk_at_entry: no capital figure rather than a wrong one.
  test "a short with no recorded margin has no capital or return figure" do
    s =
      TradeCost.summary(%{qqq_run("short") | risk_at_entry: d("2836.00")}, [
        fill("entry", "28.36", "1.05")
      ])

    assert Decimal.equal?(s.cost_to_buy, d("2836.00"))
    assert s.capital == nil
    assert s.return_pct == nil
  end

  test "a short's capital is the margin it recorded at entry" do
    run = %{
      qqq_run("short")
      | risk_at_entry: d("12000.00"),
        realized_pnl_net: d("120.00"),
        context: %{"risk_basis" => "reg_t_margin"}
    }

    s = TradeCost.summary(run, [fill("entry", "28.36", "1.05")])

    assert Decimal.equal?(s.capital, d("12000.00"))
    assert Decimal.equal?(s.return_pct, d("1.0"))
  end

  test "a combo's capital is its max loss, and the cost is the net credit received" do
    run = %{
      qqq_run("short")
      | entry_price: d("1.00"),
        exit_price: d("0.50"),
        realized_pnl: d("50.00"),
        realized_pnl_net: d("47.40"),
        risk_at_entry: d("400.00"),
        structure: "put_credit_spread",
        context: %{"risk_basis" => "max_loss"}
    }

    s = TradeCost.summary(run, [fill("entry", "2.00", "0.65"), fill("entry", "1.00", "0.65")])

    assert Decimal.equal?(s.cost_to_buy, d("100.00"))
    assert Decimal.equal?(s.capital, d("400.00"))
    assert Decimal.equal?(s.return_pct, d("11.9"))
  end

  # A model-priced fill stores fill_slippage "0": it must read as
  # unknown, not as a free fill.
  test "no two-sided quote on any fill means spread paid is unknown, not zero" do
    s = TradeCost.summary(qqq_run(), [fill("entry", "28.36", "1.05")])
    assert s.spread_paid == nil
  end

  test "falls back to gross minus fees when net was never recorded" do
    s =
      TradeCost.summary(%{qqq_run() | realized_pnl_net: nil}, [
        fill("entry", "28.36", "1.05"),
        fill("exit", "29.41", "1.06")
      ])

    assert Decimal.equal?(s.net_pnl, d("102.89"))
  end

  test "an unknown commission makes fees unknown rather than understated" do
    s = TradeCost.summary(%{qqq_run() | realized_pnl_net: nil}, [fill("entry", "28.36", nil)])

    assert s.fees == nil
    assert s.net_pnl == nil
  end
end
