defmodule TradingOptionsSim.StopLadderTest do
  use ExUnit.Case, async: true

  alias TradingOptionsSim.StopLadder

  @t0 ~U[2026-11-27 15:00:00Z]

  # Long call at 10.00, R = premium at risk = 1000, TP at 12.00,
  # underlying 100 at entry, 20m ATR 1.0.
  defp ladder(attrs \\ %{}) do
    StopLadder.new(
      Map.merge(
        %{
          sim_run_id: "run",
          strategy_version_id: "v",
          direction: "long",
          right: "C",
          entry_at: @t0,
          entry_price: Decimal.new("10.00"),
          risk_at_entry: Decimal.new("1000"),
          multiplier: 100,
          quantity: 1,
          entry_commission: Decimal.new("0"),
          take_profit_price: Decimal.new("12.00"),
          underlying_at_entry: 100.0,
          atr20m: 1.0,
          min_hold_seconds: 0
        },
        attrs
      )
    )
  end

  defp tick(mid, und, opts \\ []) do
    mid = Decimal.new(mid)

    %{
      mid: mid,
      bid: Keyword.get(opts, :bid),
      ask: Keyword.get(opts, :ask),
      premium: Keyword.get(opts, :premium, mid),
      underlying: und,
      rule_exit?: Keyword.get(opts, :rule, false)
    }
  end

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  defp run(ladder, ticks) do
    Enum.reduce(ticks, {ladder, []}, fn {tick, now}, {ladder, rows} ->
      {ladder, closed} = StopLadder.step(ladder, tick, now)
      {ladder, rows ++ closed}
    end)
  end

  defp row(rows, kind, value, with_tp),
    do:
      Enum.find(
        rows,
        &(&1.rung_kind == kind and &1.rung_value == value and &1.with_tp == with_tp)
      )

  test "a ladder has premium, underlying and time rungs, each with and without the target" do
    l = ladder()
    assert length(l.rungs) == (9 + 4 + 1) * 2
    assert Enum.count(l.rungs, & &1.with_tp) == 14
  end

  test "without a daily ATR there are no underlying rungs" do
    assert Enum.all?(ladder(%{atr20m: nil}).rungs, &(&1.kind != "underlying"))
  end

  test "atr20m scales the daily ATR to a 20-minute window" do
    assert_in_delta StopLadder.atr20m(19.5), 19.5 * :math.sqrt(20 / 390), 1.0e-9
    assert StopLadder.atr20m(nil) == nil
  end

  test "a premium rung fires on a mid dip that recovers; the no-stop rung rides to the rule exit" do
    {l, rows} =
      run(ladder(), [
        {tick("9.40", 99.9), at(60)},
        {tick("10.50", 100.4), at(120)},
        {tick("11.00", 100.8, rule: true), at(180)}
      ])

    five = row(rows, "premium", 5.0, true)
    assert five.exit_reason == "stop"
    assert Decimal.equal?(five.exit_price, Decimal.new("9.40"))
    assert_in_delta five.r_net, -0.06, 1.0e-9
    assert five.mae_pct == 6.0

    none = row(rows, "premium", nil, false)
    assert none.exit_reason == "rule"
    assert Decimal.equal?(none.exit_price, Decimal.new("11.00"))
    assert_in_delta none.r_net, 0.10, 1.0e-9
    assert none.mae_pct == 6.0
    assert none.mfe_pct == 10.0

    # The 7.5% rung didn't fire on a 6% dip.
    assert row(rows, "premium", 7.5, true).exit_reason == "rule"
    assert StopLadder.done?(l)
  end

  test "a stop exit crosses to the touch when there is a quote" do
    {_l, rows} =
      run(ladder(), [
        {tick("9.40", 99.9, bid: Decimal.new("9.30"), ask: Decimal.new("9.50")), at(60)}
      ])

    assert Decimal.equal?(row(rows, "premium", 5.0, true).exit_price, Decimal.new("9.30"))
  end

  test "an underlying rung fires on the underlying's move alone" do
    {_l, rows} =
      run(ladder(), [
        # Option price unchanged; underlying 1.1 ATR down.
        {tick("10.00", 98.9), at(60)}
      ])

    assert row(rows, "underlying", 1.0, true).exit_reason == "stop"
    assert row(rows, "underlying", 0.5, false).exit_reason == "stop"
    assert row(rows, "underlying", 1.5, true) == nil
    assert row(rows, "premium", 5.0, true) == nil
  end

  test "for a long put the adverse underlying move is up" do
    {_l, rows} = run(ladder(%{right: "P"}), [{tick("10.00", 101.1), at(60)}])
    assert row(rows, "underlying", 1.0, true).exit_reason == "stop"

    {_l, rows} = run(ladder(%{right: "P"}), [{tick("10.00", 98.0), at(60)}])
    assert row(rows, "underlying", 0.5, true) == nil
  end

  test "the time rung exits at the first 15-minute mark below entry" do
    {l, rows} =
      run(ladder(), [
        # Below entry before the first mark: nothing yet.
        {tick("9.80", 100.0), at(600)},
        # At the 15m mark it is above entry: keeps going.
        {tick("10.20", 100.1), at(900)},
        # Below entry between marks: still nothing.
        {tick("9.90", 100.0), at(1500)},
        # The 30m mark, below entry: out.
        {tick("9.90", 100.0), at(1800)}
      ])

    assert [t1, t2] = Enum.filter(rows, &(&1.rung_kind == "time"))
    assert t1.exit_reason == "stop" and t2.exit_reason == "stop"
    assert t1.exit_at == at(1800)
    refute StopLadder.done?(l)
  end

  test "with_tp: false rungs ignore the take-profit" do
    {_l, rows} = run(ladder(), [{tick("12.10", 101.0), at(60)}])

    assert row(rows, "premium", 10.0, true).exit_reason == "tp"
    assert row(rows, "premium", 10.0, false) == nil
    assert row(rows, "premium", nil, false) == nil
  end

  test "a version without a target never exits a rung on tp" do
    {_l, rows} = run(ladder(%{take_profit_price: nil}), [{tick("15.00", 103.0), at(60)}])
    refute Enum.any?(rows, &(&1.exit_reason == "tp"))
  end

  test "the rule exit waits for min_hold_seconds" do
    {_l, rows} =
      run(ladder(%{min_hold_seconds: 300}), [{tick("10.10", 100.0, rule: true), at(60)}])

    assert rows == []

    {_l, rows} =
      run(ladder(%{min_hold_seconds: 300}), [{tick("10.10", 100.0, rule: true), at(301)}])

    assert row(rows, "premium", nil, false).exit_reason == "rule"
  end

  test "close_all closes what is left as eod" do
    {l, _} = run(ladder(), [{tick("9.40", 99.9), at(60)}])
    {l, rows} = StopLadder.close_all(l, "eod", tick("9.80", 99.95), at(3600))

    assert Enum.all?(rows, &(&1.exit_reason == "eod"))
    assert row(rows, "premium", 5.0, true) == nil
    assert StopLadder.done?(l)
  end

  test "a short position's adverse premium move is up" do
    {_l, rows} =
      run(ladder(%{direction: "short", take_profit_price: Decimal.new("8.00")}), [
        {tick("10.60", 100.0), at(60)}
      ])

    five = row(rows, "premium", 5.0, true)
    assert five.exit_reason == "stop"
    assert five.mae_pct == 6.0
    assert_in_delta five.r_net, -0.06, 1.0e-9
  end
end
