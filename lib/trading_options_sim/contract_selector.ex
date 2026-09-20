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

  ## Strikes are probed, not computed

  There is no chain endpoint on `trading_hub`, and the listing increment
  is not uniform: it varies by underlying, by price level, and by expiry
  (weeklies are often denser than monthlies). Assuming "$5 for SPY"
  would be correct today and wrong for the first symbol added that
  doesn't follow it — the same false-uniformity trap that has already
  produced several silent failures in this workspace.

  So candidates are generated around the spot and each is validated via
  `TradingHub.IBKR.ContractResolver.resolve/4`, which answers
  authoritatively whether IBKR knows that contract. The first candidate
  that resolves wins. A symbol on $1 or $2.50 increments therefore works
  with no change here, just with a nearer hit.

  ## Expiry

  `"dte_target"` picks the nearest **third Friday** at or beyond the
  requested days-to-expiry. Third Friday because that is the standard
  monthly expiry: it is the most liquid, and every listed underlying has
  one. Weeklies exist for the large ETFs but not universally, so
  targeting them would reintroduce the per-symbol variation this module
  exists to remove.

  The resolved expiry is also probed, so a target landing on a month
  with no listing for that symbol falls through to the next.
  """

  @type contract :: %{expiry: String.t(), strike: Decimal.t(), right: String.t()}

  # Candidate offsets from spot, in dollars, tried nearest-first. Wide
  # enough to find a listing on a $10-increment underlying, fine enough
  # to land exactly on a $1-increment one.
  @probe_steps [0, 0.5, 1, 1.5, 2, 2.5, 3, 4, 5, 7.5, 10]

  # How many monthly expiries past the target to try before giving up.
  @expiry_lookahead 3

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
      probe_strikes(symbol, expiry, target, right, config)
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

  # Nearest-first, both directions: a strike below the target is as good
  # as one above when both are equidistant, and which exists depends on
  # where the increment grid happens to fall.
  defp probe_strikes(symbol, expiry, target, right, config) do
    candidates =
      @probe_steps
      |> Enum.flat_map(fn step -> [target + step, target - step] end)
      |> Enum.map(&Float.round(&1 * 1.0, 2))
      |> Enum.uniq()

    expiries = expiry_candidates(expiry, config)

    Enum.reduce_while(expiries, {:error, :no_listed_contract}, fn exp, acc ->
      case first_listed(symbol, exp, candidates, right) do
        {:ok, _} = found -> {:halt, found}
        {:error, _} -> {:cont, acc}
      end
    end)
  end

  # Only walk forward through expiries when the caller asked for a DTE
  # target. A deliberately named fixed_expiry is not silently swapped
  # for a different month.
  defp expiry_candidates(expiry, %{"expiry_selection" => "dte_target"}) do
    Enum.reduce(1..@expiry_lookahead, [expiry], fn _i, acc ->
      next =
        acc
        |> List.last()
        |> parse_expiry()
        |> Date.add(1)
        |> third_friday_on_or_after(25)

      acc ++ [next]
    end)
  end

  defp expiry_candidates(expiry, _config), do: [expiry]

  defp first_listed(symbol, expiry, candidates, right) do
    Enum.reduce_while(candidates, {:error, :no_listed_contract}, fn strike, acc ->
      case resolve_via_hub(symbol, expiry, strike, right) do
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
  defp call_hub(module, fun, args) do
    case IbPortfolio.HubClient.call_hub(TradingOptionsSim.HubClient, module, fun, args, 10_000) do
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

  defp parse_expiry(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>) do
    Date.new!(String.to_integer(y), String.to_integer(m), String.to_integer(d))
  end

  defp to_decimal(value) when is_float(value) do
    value |> Decimal.from_float() |> Decimal.round(2)
  end
end
