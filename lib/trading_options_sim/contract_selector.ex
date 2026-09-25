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
  confirmed with ONE resolve; the neighbouring grid points and the
  next expiries are tried only on a miss. At most five probes, typical
  case one (~148ms).

  The per-symbol grid is therefore a real assumption rather than
  something discovered at runtime, and a wrong entry produces a
  `:no_listed_contract` rather than a bad fill. It lives in
  `TradingCore.Options.ContractSelection.strike_increment/1`, with the
  IBKR evidence for each entry.

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
  which does list Feb, resolved fine.

  ## What lives where

  The pure part -- expiry candidates, the per-symbol strike grid,
  rounding and the probe order -- is
  `TradingCore.Options.ContractSelection`, shared with trading_live
  (its grid, and why XLK is absent from it, is documented there). This
  module keeps what has side effects: reading spot from trading_hub and
  probing each candidate against IBKR.
  """

  alias TradingCore.Options.ContractSelection

  @type contract :: %{expiry: String.t(), strike: Decimal.t(), right: String.t()}

  @doc """
  Resolves `leg_config` for `symbol` into a concrete, listed contract.

  The probe list -- expiries, strike grid, rounding, order -- comes from
  `TradingCore.Options.ContractSelection.candidates/4` (moved there
  2026-09-24, trading_core PR #54) so trading_live selects contracts
  with the same code. `today` is the US/Eastern trading date: UTC flips
  at 8pm ET and would target the next day's expiry for the evening.

  Returns `{:error, :no_spot}` when the underlying has no price (nothing
  to be at-the-money *of*), and `{:error, :no_listed_contract}` when no
  probed candidate resolves. Both fail closed: a strategy that cannot
  name a real contract must not activate against a guess.

  `{:error, :hub_unavailable}` means the hub didn't answer (timeout,
  unreachable, IBKR not connected) -- nothing was learned about the
  contract. SimActivator retries those later; it never retries the two
  answers above.
  """
  @spec resolve(String.t(), map(), Date.t()) :: {:ok, contract()} | {:error, atom()}
  def resolve(symbol, config, today \\ et_today())

  def resolve(symbol, %{"strike_selection" => "atm_offset"} = config, today) do
    with {:ok, spot} <- spot_price(symbol),
         {:ok, candidates} <- ContractSelection.candidates(symbol, config, spot, today) do
      first_listed(candidates, symbol, &resolve_via_hub/4)
    end
  end

  def resolve(_symbol, _config, _today), do: {:error, :unsupported_leg_config}

  defp et_today, do: DateTime.now!("America/New_York") |> DateTime.to_date()

  @doc false
  # `resolver` is the hub lookup, injectable so the probe order and the
  # fall-through are testable without a hub.
  # The only replies that ANSWER "is this contract listed?" (no).
  @definitive_misses [:not_found, :ambiguous]

  # Probes each candidate in the order ContractSelection gave, stopping
  # at the first one IBKR lists. Each miss costs ~10s on the shared
  # HubClient, which is why the list is short and ordered.
  #
  # Only :not_found / :ambiguous are ANSWERS ("IBKR has no such
  # contract"). Anything else -- a HubClient timeout behind a backlog,
  # :hub_unreachable, :not_connected -- means the question never got
  # answered, so it stops at once with {:error, :hub_unavailable} rather
  # than concluding :no_listed_contract. Until 2026-09-24 the two were
  # treated alike, so a restart that reactivated 95 versions at once
  # timed out probes for a listed contract and skipped the member
  # permanently. It also stops rather than probing on: more calls would
  # only deepen the backlog that caused the timeout.
  def first_listed(candidates, symbol, resolver) do
    Enum.reduce_while(candidates, {:error, :no_listed_contract}, fn
      %{expiry: expiry, strike: strike, right: right}, acc ->
        case resolver.(symbol, expiry, strike, right) do
          {:ok, _con_id} ->
            {:halt, {:ok, %{expiry: expiry, strike: to_decimal(strike), right: right}}}

          {:error, reason} when reason in @definitive_misses ->
            {:cont, acc}

          {:error, _transient} ->
            {:halt, {:error, :hub_unavailable}}
        end
    end)
  end

  defp resolve_via_hub(symbol, expiry, strike, right) do
    case call_hub(TradingHub.IBKR.ContractResolver, :resolve, [symbol, expiry, strike, right]) do
      {:ok, con_id} -> {:ok, con_id}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
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

      # The hub answered: it has no usable price for this symbol.
      {:ok, _no_price} ->
        {:error, :no_spot}

      {:error, :not_found} ->
        {:error, :no_spot}

      # The question never got answered (timeout, unreachable hub) --
      # transient, same distinction as first_listed/3.
      {:error, _transient} ->
        {:error, :hub_unavailable}

      # Some other reply shape: the hub did answer, just not with a
      # price. Treated as "no spot" rather than raising CaseClauseError.
      _other ->
        {:error, :no_spot}
    end
  end

  defp to_decimal(value) when is_float(value) do
    value |> Decimal.from_float() |> Decimal.round(2)
  end
end
