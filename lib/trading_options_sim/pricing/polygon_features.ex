defmodule TradingOptionsSim.Pricing.PolygonFeatures do
  @moduledoc """
  Rolling per-symbol features derived from `trading_hub`'s Polygon
  underlying feed, exposed to rule trees as `run_poly_*` snapshot keys.

  `TradingOptionsSim.PolygonRelay` folds every trade, quote and
  aggregate it relays into one `%PolygonFeatures{}` per symbol and
  writes it to a named ETS table; `ContractMonitor` merges
  `snapshot/1` into every evaluation. The fold functions are pure and
  take the receive time as an argument, so the tests drive time
  directly rather than sleeping.

  ## Keys

  | key | meaning | needs |
  |---|---|---|
  | `run_poly_last` | last trade price | trade in the last 30s |
  | `run_poly_spread_bps` | quoted spread, bps of mid | fresh quote |
  | `run_poly_imbalance` | `(bid_size - ask_size) / (bid_size + ask_size)`, -1..1 | fresh quote WITH both sizes |
  | `run_poly_imbalance_ema` | the same, time-decayed (10s time constant) | as above |
  | `run_poly_ret_1m_bps` / `run_poly_ret_5m_bps` | trade-price return over the window, bps | trade history spanning the window |
  | `run_poly_vwap_dev_bps` | last trade vs regular-session VWAP, bps | sized regular-hours trades today |
  | `run_poly_minute_volume` | latest per-minute bar volume | bar in the last 150s |
  | `run_poly_rel_volume` | latest bar / mean of up to 20 prior bars | ≥ 5 prior bars |

  ## Absent means unknown — never zero

  A key whose inputs are stale, incomplete or not yet warmed up is
  **omitted**, not set to `0`. `TradingCore.RuleEngine` fails closed on
  a missing key, which is the correct behaviour: a quote without sizes
  has an *unknown* imbalance, and reporting `0.0` would let an
  `imbalance < 0.1` rule fire on no information at all. Same rule for a
  zero denominator (sizes `0/0`, an empty VWAP).

  ## Sampling

  Returns read a trade-price buffer sampled at most once per second and
  kept for 6 minutes, so memory is bounded
  regardless of tick rate. A return is only reported when the buffer
  holds a sample at or before the window start and that sample is not
  more than 30s older than it — a gap in the feed yields no value
  rather than a return measured over a silently longer window.
  """

  @table __MODULE__

  @fresh_ms 30_000
  @volume_fresh_ms 150_000
  @sample_every_ms 1_000
  @buffer_ms 360_000
  @window_slack_ms 30_000
  @ema_tau_ms 10_000
  @volume_history 20
  @min_volume_history 5

  defstruct quote: nil,
            quote_at: nil,
            imbalance_ema: nil,
            last_trade: nil,
            last_trade_at: nil,
            samples: :queue.new(),
            last_sample_at: nil,
            vwap_date: nil,
            vwap_pv: 0.0,
            vwap_v: 0.0,
            bar_volume: nil,
            bar_at: nil,
            prior_bars: []

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  # --- ETS ------------------------------------------------------------------

  @doc "Creates the named table. Called once by `PolygonRelay.init/1`, which owns it."
  @spec create_table() :: :ok
  def create_table do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    :ok
  end

  @doc "Current features for `symbol` (or a fresh struct if none)."
  @spec get(String.t()) :: t()
  def get(symbol) do
    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, symbol) do
      [{^symbol, features}] -> features
      _ -> new()
    end
  end

  @doc false
  @spec put(String.t(), t()) :: true
  def put(symbol, features), do: :ets.insert(@table, {symbol, features})

  @doc "The `run_poly_*` snapshot for `symbol` right now — `%{}` if nothing is known."
  @spec snapshot(String.t()) :: map()
  def snapshot(symbol), do: symbol |> get() |> to_snapshot(now_ms())

  @doc false
  def now_ms, do: System.system_time(:millisecond)

  # --- Folds ----------------------------------------------------------------

  @spec apply_trade(t(), map(), integer()) :: t()
  def apply_trade(%__MODULE__{} = f, data, now) do
    case to_float(Map.get(data, :last)) do
      price when is_float(price) and price > 0 ->
        %{f | last_trade: price, last_trade_at: now}
        |> sample(price, now)
        |> accumulate_vwap(price, to_float(Map.get(data, :size)), Map.get(data, :timestamp))

      _ ->
        f
    end
  end

  @spec apply_quote(t(), map(), integer()) :: t()
  def apply_quote(%__MODULE__{} = f, data, now) do
    bid = to_float(Map.get(data, :bid))
    ask = to_float(Map.get(data, :ask))

    if is_float(bid) and is_float(ask) and bid > 0 and ask >= bid do
      q = %{
        bid: bid,
        ask: ask,
        bid_size: to_float(Map.get(data, :bid_size)),
        ask_size: to_float(Map.get(data, :ask_size))
      }

      %{f | quote: q, quote_at: now, imbalance_ema: update_ema(f, imbalance(q), now)}
    else
      f
    end
  end

  @spec apply_aggregate(t(), map(), integer()) :: t()
  def apply_aggregate(%__MODULE__{} = f, data, now) do
    case to_float(Map.get(data, :volume)) do
      v when is_float(v) and v >= 0 ->
        prior =
          if is_nil(f.bar_volume),
            do: f.prior_bars,
            else: Enum.take([f.bar_volume | f.prior_bars], @volume_history)

        %{f | bar_volume: v, bar_at: now, prior_bars: prior}

      _ ->
        f
    end
  end

  # --- Snapshot -------------------------------------------------------------

  @spec to_snapshot(t(), integer()) :: map()
  def to_snapshot(%__MODULE__{} = f, now) do
    quote_fresh? = fresh?(f.quote_at, now, @fresh_ms)
    trade_fresh? = fresh?(f.last_trade_at, now, @fresh_ms)
    bar_fresh? = fresh?(f.bar_at, now, @volume_fresh_ms)

    [
      {"run_poly_last", trade_fresh? && f.last_trade},
      {"run_poly_spread_bps", quote_fresh? && spread_bps(f.quote)},
      {"run_poly_imbalance", quote_fresh? && imbalance(f.quote)},
      {"run_poly_imbalance_ema", quote_fresh? && f.imbalance_ema},
      {"run_poly_ret_1m_bps", trade_fresh? && return_bps(f, 60_000, now)},
      {"run_poly_ret_5m_bps", trade_fresh? && return_bps(f, 300_000, now)},
      {"run_poly_vwap_dev_bps", trade_fresh? && vwap_dev_bps(f, now)},
      {"run_poly_minute_volume", bar_fresh? && f.bar_volume},
      {"run_poly_rel_volume", bar_fresh? && rel_volume(f)}
    ]
    |> Enum.filter(fn {_k, v} -> is_number(v) end)
    |> Map.new()
  end

  # --- Internals ------------------------------------------------------------

  defp fresh?(nil, _now, _max), do: false
  defp fresh?(at, now, max), do: now - at <= max

  defp spread_bps(%{bid: bid, ask: ask}) do
    mid = (bid + ask) / 2
    (ask - bid) / mid * 10_000
  end

  defp imbalance(%{bid_size: b, ask_size: a}) when is_float(b) and is_float(a) and b + a > 0,
    do: (b - a) / (b + a)

  defp imbalance(_quote), do: nil

  # A quote with unknown sizes leaves the EMA where it was rather than
  # pulling it toward zero.
  defp update_ema(f, nil, _now), do: f.imbalance_ema
  defp update_ema(%{imbalance_ema: nil}, x, _now), do: x

  defp update_ema(%{imbalance_ema: ema, quote_at: prev_at}, x, now) do
    alpha = 1 - :math.exp(-max(now - prev_at, 0) / @ema_tau_ms)
    ema + alpha * (x - ema)
  end

  defp sample(%{last_sample_at: last} = f, price, now)
       when is_nil(last) or now - last >= @sample_every_ms do
    samples = drop_old(:queue.in({now, price}, f.samples), now - @buffer_ms)
    %{f | samples: samples, last_sample_at: now}
  end

  defp sample(f, _price, _now), do: f

  defp drop_old(q, cutoff) do
    case :queue.peek(q) do
      {:value, {at, _}} when at < cutoff -> drop_old(:queue.drop(q), cutoff)
      _ -> q
    end
  end

  # The newest sample at or before the window start; nil if the buffer
  # doesn't reach back that far or the nearest sample is too old.
  defp return_bps(%{last_trade: last} = f, window, now) do
    start = now - window

    base =
      f.samples
      |> :queue.to_list()
      |> Enum.take_while(fn {at, _} -> at <= start end)
      |> List.last()

    case base do
      {at, price} when start - at <= @window_slack_ms -> (last - price) / price * 10_000
      _ -> nil
    end
  end

  defp accumulate_vwap(f, _price, size, _ts) when not is_float(size) or size <= 0, do: f
  defp accumulate_vwap(f, _price, _size, nil), do: f

  defp accumulate_vwap(f, price, size, %DateTime{} = ts) do
    case regular_session_date(ts) do
      nil ->
        f

      date when date == f.vwap_date ->
        %{f | vwap_pv: f.vwap_pv + price * size, vwap_v: f.vwap_v + size}

      date ->
        %{f | vwap_date: date, vwap_pv: price * size, vwap_v: size}
    end
  end

  defp accumulate_vwap(f, _price, _size, _ts), do: f

  # ET trading date if `ts` falls in 09:30-16:00 ET, else nil.
  # Pre/post-market prints are excluded so the VWAP matches the one a
  # chart would show for the regular session.
  defp regular_session_date(ts) do
    case DateTime.shift_zone(ts, "America/New_York") do
      {:ok, et} ->
        t = Time.new!(et.hour, et.minute, et.second)

        if Time.compare(t, ~T[09:30:00]) != :lt and Time.compare(t, ~T[16:00:00]) == :lt,
          do: DateTime.to_date(et)

      _ ->
        nil
    end
  end

  # Yesterday's VWAP is not today's: before today's first regular-hours
  # print, report nothing rather than a deviation from a stale session.
  defp vwap_dev_bps(%{vwap_v: v}, _now) when v <= 0, do: nil

  defp vwap_dev_bps(%{vwap_pv: pv, vwap_v: v, last_trade: last, vwap_date: date}, now) do
    if date == et_date(now) do
      vwap = pv / v
      (last - vwap) / vwap * 10_000
    end
  end

  defp et_date(now_ms) do
    now_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.shift_zone!("America/New_York")
    |> DateTime.to_date()
  end

  defp rel_volume(%{prior_bars: prior}) when length(prior) < @min_volume_history, do: nil

  defp rel_volume(%{prior_bars: prior, bar_volume: v}) do
    mean = Enum.sum(prior) / length(prior)
    if mean > 0, do: v / mean
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(_), do: nil
end
