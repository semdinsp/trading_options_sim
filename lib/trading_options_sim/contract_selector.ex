defmodule TradingOptionsSim.ContractSelector do
  @moduledoc """
  Resolves an ATM-relative `option_leg_config` into a concrete
  `{expiry, strike, right}` per symbol, against the live IBKR chain.

  ## Why this exists

  `option_leg_config` previously supported only `"fixed_strike"` — one
  literal strike applied to every member of a target pool. That makes a
  multi-symbol strategy impossible: SPY trades near 763 and QQQ near
  722, so no single strike is near-the-money for both. A pool holding
  both produced one usable contract and one deep-OTM or non-existent
  one.

  It also goes stale. A strike chosen at today's spot stops being ATM
  after a 2% move, so a strategy silently changes character without its
  configuration changing. That is not hypothetical here: ten strategies
  seeded 2026-09-17 with literal strikes of 762/716 referenced contracts
  that **do not exist at all** — SPY and QQQ list in $5 increments at
  these levels — and TWS rejected every subscription with error 200
  until they were corrected by hand.

  ## Rounding first, probing only to confirm

  An earlier version of this module probed candidate strikes outward
  from spot until one resolved. Measured against the live hub, that is
  unusable: a resolve HIT costs ~148ms, but a MISS costs a full
  **10 seconds** — IBKR never replies for a contract it doesn't know, so
  every miss runs to timeout. Probing ~20 candidates for a symbol whose
  grid is offset could burn 200 seconds.

  Worse, `IbPortfolio.HubClient` is a single GenServer that serializes
  every hub call for this app. A probe loop doesn't just make itself
  slow, it blocks `IBKRLive` subscriptions and every other hub consumer
  behind it — observed live as a 20-message backlog on that process.

  So the strike is ROUNDED to the underlying's known increment and
  confirmed with ONE resolve. If that misses, the two neighbouring
  grid points are tried and then it gives up. Worst case is three
  calls (~20s), typical case one (~148ms).

  `@strike_increments` is therefore a real assumption rather than
  something discovered at runtime, and a wrong entry produces a
  `:no_listed_contract` rather than a bad fill. Each entry below is
  verified against IBKR, and an unlisted symbol falls back to $1 —
  the densest common grid, so a miss is a miss rather than a silent
  skip past a strike that exists.

  ## Expiry

  `"dte_target"` picks the nearest **third Friday** at or beyond the
  requested days-to-expiry. Third Friday because that is the standard
  monthly expiry: it is the most liquid, and every listed underlying has
  one. Weeklies exist for the large ETFs but not universally, so
  targeting them would reintroduce the per-symbol variation this module
  exists to remove.

  The expiry is probed too, and a target landing on a month with no
  listing for that symbol falls through to the next two third Fridays.
  That is not hypothetical: on 2026-09-23 SPY listed Dec, Jan and Mar
  but NOT Feb 2027, so every 120-DTE SPY leg (target 20270219) failed
  with `:no_listed_contract` from the day it was created, while QQQ,
  which does list Feb, resolved fine. `candidates/3` orders the probes
  so the fall-through stays cheap -- see its doc.
  """

  @type contract :: %{expiry: String.t(), strike: Decimal.t(), right: String.t()}

  # Strike grid per underlying, probed against IBKR 2026-09-20 on the
  # 20261120 monthly. Increments widen with price and vary by expiry,
  # so these are a claim about the liquid monthlies this app targets,
  # not about every listing.
  #
  #   SPY  760C ok, 762C/763C not found            -> 5.0
  #   QQQ  715C/720C ok                            -> 5.0
  #   XLF   53C ok,  53.5C not found,  54C ok      -> 1.0
  #   XLK  275C ok, 276C/277.5C/280C not found     -> UNRESOLVED
  #
  # XLK is deliberately absent. 275 lists while 276, 277.5 and 280 do
  # not, which fits no single increment, and pinning it down needs more
  # probes than is reasonable against a shared HubClient at 10s per
  # miss. It therefore takes @default_increment and will most likely
  # return :no_listed_contract until someone measures it properly --
  # which is the correct failure: no contract beats a wrong one.
  @strike_increments %{"SPY" => 5.0, "QQQ" => 5.0, "XLF" => 1.0}

  # $1 is the densest common grid, so an unknown symbol misses rather
  # than silently skipping past a strike that exists.
  @default_increment 1.0

  @doc """
  Resolves `leg_config` for `symbol` into a concrete contract.

  Returns `{:error, :no_spot}` when the underlying has no price (nothing
  to be at-the-money *of*), and `{:error, :no_listed_contract}` when no
  probed candidate resolves. Both fail closed: a strategy that cannot
  name a real contract must not activate against a guess.
  """
  @spec resolve(String.t(), map()) :: {:ok, contract()} | {:error, atom()}
  def resolve(symbol, %{"strike_selection" => "atm_offset"} = config) do
    with {:ok, spot} <- spot_price(symbol),
         {:ok, expiry} <- resolve_expiry(config),
         right when right in ["C", "P"] <- Map.get(config, "right") do
      target = spot + (config["strike_offset"] || 0)
      expiries = [expiry | fallback_expiries(expiry, config)]

      symbol
      |> candidates(target, expiries)
      |> first_listed(symbol, right, &resolve_via_hub/4)
    else
      {:error, reason} -> {:error, reason}
      _invalid_right -> {:error, :unsupported_leg_config}
    end
  end

  def resolve(_symbol, _config), do: {:error, :unsupported_leg_config}

  @doc """
  The nearest third Friday at or beyond `dte_target` days from today,
  as this app's `"YYYYMMDD"` wire format.

  Exposed for tests and for callers that want the expiry without
  resolving a strike.
  """
  @spec third_friday_on_or_after(Date.t(), non_neg_integer()) :: String.t()
  def third_friday_on_or_after(from, dte_target) do
    target = Date.add(from, dte_target)

    Stream.iterate(target, &Date.add(&1, 1))
    |> Enum.find(&third_friday?/1)
    |> Calendar.strftime("%Y%m%d")
  end

  defp resolve_expiry(%{"expiry_selection" => "dte_target"} = config) do
    dte = config["dte_target"] || 45
    {:ok, third_friday_on_or_after(Date.utc_today(), dte)}
  end

  # A literal expiry is still honoured, so an ATM strike can be paired
  # with a deliberately chosen expiry (a specific LEAPS, say).
  defp resolve_expiry(%{"fixed_expiry" => expiry}) when is_binary(expiry), do: {:ok, expiry}

  defp resolve_expiry(_config), do: {:error, :unsupported_leg_config}

  defp third_friday?(date) do
    Date.day_of_week(date) == 5 and date.day in 15..21
  end

  # Only a dte_target expiry falls through. A fixed_expiry is a
  # deliberate choice (a specific LEAPS), and silently trading a
  # different month would be worse than not trading at all.
  defp fallback_expiries(expiry, %{"expiry_selection" => "dte_target"}) do
    next = expiry |> wire_date() |> third_friday_on_or_after(1)
    [next, next |> wire_date() |> third_friday_on_or_after(1)]
  end

  defp fallback_expiries(_expiry, _config), do: []

  defp wire_date(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>),
    do: Date.new!(String.to_integer(y), String.to_integer(m), String.to_integer(d))

  @doc """
  The ordered `{expiry, strike}` probes for `symbol` at `target`.

  The rounded strike on each expiry first, then one grid step either
  side on the FIRST expiry only. At most `length(expiries) + 2` probes.

  Ordered this way because an unlisted expiry and an off-grid strike
  both cost a full 10s miss, and they are not equally likely: for SPY
  and QQQ at a $5 grid, the rounded strike is essentially always
  listed, so a miss on it almost always means the MONTH is missing.
  Probing neighbours on a missing month first would spend 30s learning
  nothing. Bounded deliberately -- see the moduledoc on why an
  unbounded probe loop is a denial of service against the shared
  HubClient rather than merely slow.
  """
  @spec candidates(String.t(), number(), [String.t()]) :: [{String.t(), float()}]
  def candidates(symbol, target, [first | _] = expiries) do
    increment = Map.get(@strike_increments, symbol, @default_increment)
    rounded = Float.round(Float.round(target / increment) * increment, 2)

    neighbours =
      [rounded + increment, rounded - increment]
      |> Enum.map(&{first, Float.round(&1, 2)})

    (Enum.map(expiries, &{&1, rounded}) ++ neighbours) |> Enum.uniq()
  end

  @doc false
  # `resolver` is the hub lookup, injectable so the probe order and the
  # fall-through are testable without a hub.
  def first_listed(candidates, symbol, right, resolver) do
    Enum.reduce_while(candidates, {:error, :no_listed_contract}, fn {expiry, strike}, acc ->
      case resolver.(symbol, expiry, strike, right) do
        {:ok, _con_id} ->
          {:halt, {:ok, %{expiry: expiry, strike: to_decimal(strike), right: right}}}

        {:error, _} ->
          {:cont, acc}
      end
    end)
  end

  defp resolve_via_hub(symbol, expiry, strike, right) do
    case call_hub(TradingHub.IBKR.ContractResolver, :resolve, [symbol, expiry, strike, right]) do
      {:ok, con_id} -> {:ok, con_id}
      other -> {:error, other}
    end
  end

  # Unwraps HubClient's own {:ok, <remote return>} envelope so callers
  # see the remote function's result directly. An unreachable hub is an
  # error like any other -- callers fail closed on it.
  # Deliberately longer than IBKR's own miss cost. A resolve HIT returns
  # in ~148ms, but a MISS takes a full 10 seconds -- IBKR never replies
  # for a contract it does not know, so the request runs to ITS timeout.
  # At a 10s budget here the two raced, and a miss surfaced as
  # `{:erpc, :timeout}` instead of the `{:error, :not_found}` the probe
  # logic is written to handle. Observed live 2026-09-20:
  #
  #   [warning] TradingHub.IBKR.ContractResolver.resolve/4 RPC failed:
  #             Erlang error: {:erpc, :timeout}
  #
  # 15s leaves headroom for the remote timeout to fire and return a real
  # answer, which is the difference between "this strike is not listed"
  # (try the next one) and "something went wrong" (give up on the
  # symbol).
  @hub_call_timeout_ms 15_000

  defp call_hub(module, fun, args) do
    case IbPortfolio.HubClient.call_hub(
           TradingOptionsSim.HubClient,
           module,
           fun,
           args,
           @hub_call_timeout_ms
         ) do
      {:ok, remote_result} -> remote_result
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :hub_unreachable}
  end

  # Read from trading_hub rather than this app's own PriceRelay cache:
  # resolution happens at ACTIVATION, before any monitor exists, so
  # there is no local tick to read yet. `last` is preferred over the
  # bid/ask midpoint because it is the field always present outside
  # session hours -- bid/ask come back as -1.0 when the book is closed.
  defp spot_price(symbol) do
    case call_hub(TradingHub.MarketData.Manager, :get_last_price, [symbol]) do
      {:ok, %{last: last}} when is_number(last) and last > 0 ->
        {:ok, last}

      {:ok, %{close: close}} when is_number(close) and close > 0 ->
        {:ok, close}

      _other ->
        {:error, :no_spot}
    end
  end

  defp to_decimal(value) when is_float(value) do
    value |> Decimal.from_float() |> Decimal.round(2)
  end
end
