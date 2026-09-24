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

  # A short receives the premium and needs margin this simulator does
  # not model: no capital figure rather than a wrong one.
  test "a short has no capital or return figure" do
    s = TradeCost.summary(qqq_run("short"), [fill("entry", "28.36", "1.05")])

    assert Decimal.equal?(s.cost_to_buy, d("2836.00"))
    assert s.capital == nil
    assert s.return_pct == nil
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
