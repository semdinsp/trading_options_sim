defmodule TradingOptionsSim.StopLadder do
  @moduledoc """
  A ladder of virtual stops on one run: every alternative stop measured
  on the same quote stream the run's own exits see, so a version's stop
  can be sized from its own trades (`Sim.stop_sizing/2`) instead of from
  A/B pairs that change stop and target together.

  Pure: `ContractMonitor` builds one at entry (`new/1`), feeds it every
  tick (`step/3`, also after the real run has closed), closes what is
  left at the end of the session (`close_all/4`) and writes each closed
  rung as a `sim_run_stop_ladder` row.

  ## Rungs

    * `"premium"`, value X: stop when the MID is X% against the entry
      premium; X in #{inspect([5, 7.5, 10, 15, 20, 25, 35, 50])}, plus value
      `nil` = no stop.
    * `"underlying"`, value k: stop when the underlying has moved k x the
      20-minute ATR against the position from its price at entry; k in
      #{inspect([0.5, 1.0, 1.5, 2.0])}. The 20-minute ATR is the daily
      ATR(14) x sqrt(20 / 390), the random-walk scaling of the daily
      range to a 20-minute window: known at every entry, the same after
      a restart, and reproducible by trading_live from the same inputs.
      Absent when there is no daily ATR at entry.
    * `"time"`, value 15: a "not working" stop at the first 15-minute
      mark after entry at which the mid is below entry (above, for a
      short).

  Every rung exists twice, `with_tp: true` (the version's own
  take-profit level from entry) and `with_tp: false` (none), so stop and
  target effects can be separated. Every rung keeps the version's rule
  exit (after `min_hold_seconds`) and the end-of-session flatten.

  ## Prices

  A rung exits at the price the real run would get for the same reason:
  mid plus the worked fraction of the spread against the position (0.5,
  the touch, for a stop or EOD; 0.25 for a target or rule exit; see
  `ContractMonitor.fill_price_for/4`), or the model price without a
  quote. Stops and MAE/MFE are judged on the mid; the target on the
  option price the real run's target uses (`premium`). R is net P&L over
  premium at risk, the `Sim.r_multiple` basis, with the exit commission
  taken equal to the entry's.
  """

  @ladder_version 1
  @premium_rungs [5, 7.5, 10, 15, 20, 25, 35, 50, nil]
  @underlying_rungs [0.5, 1.0, 1.5, 2.0]
  @time_rung_minutes 15
  @stop_fraction Decimal.new("0.5")
  @worked_fraction Decimal.new("0.25")
  @atr20m_scale :math.sqrt(20 / 390)

  def ladder_version, do: @ladder_version
  def premium_rungs, do: @premium_rungs
  def underlying_rungs, do: @underlying_rungs

  @doc "The 20-minute ATR used by the underlying rungs, from a daily ATR."
  @spec atr20m(number() | Decimal.t() | nil) :: float() | nil
  def atr20m(nil), do: nil
  def atr20m(%Decimal{} = atr), do: atr20m(Decimal.to_float(atr))
  def atr20m(atr) when is_number(atr) and atr > 0, do: atr * @atr20m_scale
  def atr20m(_atr), do: nil

  @doc """
  A ladder for a run that has just entered. `attrs`: `:sim_run_id`,
  `:strategy_version_id`, `:direction`, `:right`, `:entry_at`,
  `:entry_price`, `:risk_at_entry`, `:multiplier`, `:quantity`,
  `:entry_commission`, `:take_profit_price` (nil = the version has no
  target), `:underlying_at_entry`, `:atr20m`, `:min_hold_seconds`.
  """
  def new(attrs) do
    rungs =
      for(value <- @premium_rungs, with_tp <- [true, false], do: {"premium", value, with_tp}) ++
        if(is_number(attrs[:atr20m]) and is_number(attrs[:underlying_at_entry]),
          do:
            for(k <- @underlying_rungs, with_tp <- [true, false], do: {"underlying", k, with_tp}),
          else: []
        ) ++
        for(with_tp <- [true, false], do: {"time", @time_rung_minutes, with_tp})

    %{
      sim_run_id: attrs.sim_run_id,
      strategy_version_id: attrs.strategy_version_id,
      direction: attrs.direction,
      right: attrs.right,
      entry_at: attrs.entry_at,
      entry_price: attrs.entry_price,
      risk_at_entry: attrs.risk_at_entry,
      multiplier: attrs.multiplier,
      quantity: attrs.quantity,
      entry_commission: attrs[:entry_commission] || Decimal.new(0),
      take_profit_price: attrs[:take_profit_price],
      underlying_at_entry: attrs[:underlying_at_entry],
      atr20m: attrs[:atr20m],
      min_hold_seconds: attrs[:min_hold_seconds] || 0,
      next_time_mark: DateTime.add(attrs.entry_at, @time_rung_minutes * 60, :second),
      rungs:
        Enum.map(rungs, fn {kind, value, with_tp} ->
          %{
            kind: kind,
            value: value,
            with_tp: with_tp,
            best: attrs.entry_price,
            worst: attrs.entry_price
          }
        end)
    }
  end

  @doc """
  One tick. `tick`: `:mid` (Decimal or nil), `:bid`/`:ask` (Decimal or
  nil), `:premium` (the option price the real target is checked on),
  `:underlying` (number or nil), `:rule_exit?` (the version's exit rule
  on this snapshot). Returns `{ladder, closed}`, `closed` being the rows
  for the rungs that closed on this tick. Call only in session.
  """
  def step(ladder, tick, now) do
    mid = tick[:mid] || tick[:premium]

    if is_nil(mid) do
      {ladder, []}
    else
      time_mark? = DateTime.compare(now, ladder.next_time_mark) != :lt
      rule? = tick[:rule_exit?] == true and min_hold_elapsed?(ladder, now)

      {open, closed} =
        Enum.reduce(ladder.rungs, {[], []}, fn rung, {open, closed} ->
          rung = track(rung, mid, ladder.direction)

          case exit_reason(ladder, rung, tick, mid, time_mark?, rule?) do
            nil -> {[rung | open], closed}
            reason -> {open, [close_row(ladder, rung, reason, tick, now) | closed]}
          end
        end)

      ladder = %{ladder | rungs: Enum.reverse(open)}
      ladder = if time_mark?, do: advance_time_mark(ladder, now), else: ladder
      {ladder, Enum.reverse(closed)}
    end
  end

  @doc "Closes every open rung with `reason` (\"eod\") at this tick's prices."
  def close_all(ladder, reason, tick, now) do
    mid = tick[:mid] || tick[:premium]

    if is_nil(mid) do
      {ladder, []}
    else
      rows =
        Enum.map(ladder.rungs, fn rung ->
          close_row(ladder, track(rung, mid, ladder.direction), reason, tick, now)
        end)

      {%{ladder | rungs: []}, rows}
    end
  end

  def done?(%{rungs: []}), do: true
  def done?(_ladder), do: false

  # -- rung logic --------------------------------------------------------

  defp exit_reason(ladder, rung, tick, mid, time_mark?, rule?) do
    cond do
      stop_hit?(ladder, rung, tick, mid, time_mark?) -> "stop"
      rung.with_tp and tp_hit?(ladder, tick) -> "tp"
      rule? -> "rule"
      true -> nil
    end
  end

  defp stop_hit?(_ladder, %{kind: "premium", value: nil}, _tick, _mid, _time_mark?), do: false

  defp stop_hit?(ladder, %{kind: "premium", value: pct}, _tick, mid, _time_mark?) do
    move = Decimal.mult(ladder.entry_price, Decimal.div(dec(pct), 100))

    if ladder.direction == "short",
      do: Decimal.compare(mid, Decimal.add(ladder.entry_price, move)) != :lt,
      else: Decimal.compare(mid, Decimal.sub(ladder.entry_price, move)) != :gt
  end

  defp stop_hit?(ladder, %{kind: "underlying", value: k}, tick, _mid, _time_mark?) do
    case tick[:underlying] do
      und when is_number(und) ->
        (und - ladder.underlying_at_entry) * underlying_sign(ladder) <= -k * ladder.atr20m

      _ ->
        false
    end
  end

  defp stop_hit?(ladder, %{kind: "time"}, _tick, mid, true) do
    if ladder.direction == "short",
      do: Decimal.gt?(mid, ladder.entry_price),
      else: Decimal.lt?(mid, ladder.entry_price)
  end

  defp stop_hit?(_ladder, %{kind: "time"}, _tick, _mid, _time_mark?), do: false

  defp tp_hit?(%{take_profit_price: nil}, _tick), do: false

  defp tp_hit?(ladder, tick) do
    case tick[:premium] || tick[:mid] do
      nil ->
        false

      price ->
        if ladder.direction == "short",
          do: Decimal.compare(price, ladder.take_profit_price) != :gt,
          else: Decimal.compare(price, ladder.take_profit_price) != :lt
    end
  end

  # +1 when the position gains as the underlying rises (long call, short
  # put), -1 when it gains as it falls (long put, short call).
  defp underlying_sign(%{right: right, direction: direction}) do
    r = if right == "P", do: -1, else: 1
    d = if direction == "short", do: -1, else: 1
    r * d
  end

  defp min_hold_elapsed?(ladder, now),
    do: DateTime.diff(now, ladder.entry_at, :second) >= ladder.min_hold_seconds

  # The next 15-minute mark strictly after now.
  defp advance_time_mark(ladder, now) do
    step = @time_rung_minutes * 60
    elapsed = DateTime.diff(now, ladder.entry_at, :second)
    marks = div(elapsed, step) + 1
    %{ladder | next_time_mark: DateTime.add(ladder.entry_at, marks * step, :second)}
  end

  defp track(rung, mid, direction) do
    {better, worse} =
      if direction == "short",
        do: {&Decimal.lt?/2, &Decimal.gt?/2},
        else: {&Decimal.gt?/2, &Decimal.lt?/2}

    rung
    |> then(&if(better.(mid, &1.best), do: %{&1 | best: mid}, else: &1))
    |> then(&if(worse.(mid, &1.worst), do: %{&1 | worst: mid}, else: &1))
  end

  # -- rows --------------------------------------------------------------

  defp close_row(ladder, rung, reason, tick, now) do
    price = exit_price(ladder, reason, tick)
    sign = if ladder.direction == "short", do: -1, else: 1
    size = ladder.multiplier * ladder.quantity

    gross =
      price |> Decimal.sub(ladder.entry_price) |> Decimal.mult(size) |> Decimal.mult(sign)

    net = gross |> Decimal.sub(ladder.entry_commission) |> Decimal.sub(ladder.entry_commission)

    %{
      sim_run_id: ladder.sim_run_id,
      strategy_version_id: ladder.strategy_version_id,
      ladder_version: @ladder_version,
      rung_kind: rung.kind,
      rung_value: rung.value && rung.value / 1,
      with_tp: rung.with_tp,
      exit_price: price,
      exit_reason: reason,
      exit_at: now,
      underlying_at_exit: tick[:underlying] && tick[:underlying] / 1,
      pnl_net: net,
      r_net: r_net(net, ladder.risk_at_entry),
      mae_pct: excursion_pct(ladder, rung.worst, -sign),
      mfe_pct: excursion_pct(ladder, rung.best, sign)
    }
  end

  defp exit_price(ladder, reason, tick) do
    fraction = if reason in ["stop", "eod"], do: @stop_fraction, else: @worked_fraction
    action = if ladder.direction == "short", do: "buy", else: "sell"

    case {tick[:bid], tick[:ask]} do
      {%Decimal{} = bid, %Decimal{} = ask} ->
        bid
        |> TradingOptionsSim.ContractMonitor.touch_price(ask, action, fraction)
        |> Decimal.round(2)

      _ ->
        Decimal.round(tick[:premium] || tick[:mid], 2)
    end
  end

  defp r_net(_net, nil), do: nil

  defp r_net(net, %Decimal{} = risk) do
    if Decimal.gt?(risk, 0), do: net |> Decimal.div(risk) |> Decimal.to_float(), else: nil
  end

  defp excursion_pct(ladder, price, sign) do
    pct =
      price
      |> Decimal.sub(ladder.entry_price)
      |> Decimal.div(ladder.entry_price)
      |> Decimal.to_float()

    Float.round(max(pct * 100 * sign, 0.0), 4)
  end

  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(n) when is_float(n), do: Decimal.from_float(n)
end
