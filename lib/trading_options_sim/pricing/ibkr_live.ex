defmodule TradingOptionsSim.Pricing.IBKRLive do
  @moduledoc """
  Real IBKR option quotes/greeks, consumed from `trading_hub`'s
  `TickOptionComputation` broadcast (PR #102, `e3e909e`/`995c2c3`) —
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §5a v2. Swappable alternative to
  `TradingOptionsSim.Pricing.BlackScholes`; **not the default** (see
  `ContractMonitor`'s `:pricing_backend` option) until someone confirms
  live greeks streaming actually works end-to-end against real TWS.

  ## Real, confirmed-unverified risk — do not treat this as production-ready

  `trading_hub`'s own commit message for PR #102 states plainly: whether
  `TickOptionComputation` greeks stream automatically for a plain `"OPT"`
  `reqMktData` subscription, or need an explicit generic-tick code (IBKR's
  "106") that `trading_hub` does not currently send
  (`Subscriptions.send_req_mkt_data/3` hardcodes `@generic_ticks ""`), is
  **unverified against live TWS**. This module may simply never receive
  any broadcast at all until that's resolved on `trading_hub`'s side —
  that failure mode is indistinguishable from "no options market open" at
  this layer, so don't debug this module first if greeks never arrive;
  check `trading_hub`'s own subscription behavior against a real
  connection before assuming a bug here.

  ## Wire shape, verified directly against `trading_hub`'s real code

  `TradingHub.IBKR.MessageHandler`'s `TickOptionComputation` clause
  broadcasts a plain `%TradingHub.Message{type: :price, symbol: <the
  OCC-style string this contract was subscribed under>, data: %{
  implied_vol:, delta:, opt_price:, pv_dividend:, gamma:, vega:, theta:,
  und_price:}}` on `"prices:<symbol>"` — it reuses the existing `:price`
  message type and topic shape, **not** a distinct `:greeks` type;
  identity comes only from the `symbol` string, never a structured
  con_id/expiry/strike/right field. `data` keys are exactly as listed
  above (confirmed against `message_handler.ex` and its own test file);
  any other key is absent, not `nil` — this module treats a missing key
  as "no computation received yet," matching `BlackScholes.compute/1`'s
  "never fabricate a quantity/price" posture used elsewhere in this app.

  This module deliberately mirrors `PriceRelay`'s own pattern: subscribe
  once (here, per-monitor, to the resolved contract's own OCC symbol
  topic) and cache the latest tick, rather than polling — same
  event-driven mandate as `ContractMonitor` itself (plan §5's own note).
  """

  use GenServer

  defstruct [:occ_symbol, last_tick: nil]

  @type occ_symbol :: String.t()

  @doc """
  Starts a listener for one contract's OCC-style subscription symbol
  (the string `trading_hub`'s `Subscriptions.subscribe/2` was called
  with for this contract — NOT the plain underlying ticker; see this
  module's own moduledoc on why identity is symbol-string-only today).
  """
  def start_link(opts) do
    occ_symbol = Keyword.fetch!(opts, :occ_symbol)
    GenServer.start_link(__MODULE__, opts, name: via(occ_symbol))
  end

  defp via(occ_symbol) do
    {:via, Registry, {TradingOptionsSim.MonitorRegistry, {:ibkr_live, occ_symbol}}}
  end

  @doc "Looks up the running listener for `occ_symbol`, if any."
  @spec whereis(occ_symbol()) :: pid() | nil
  def whereis(occ_symbol) do
    case Registry.lookup(TradingOptionsSim.MonitorRegistry, {:ibkr_live, occ_symbol}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  The last-received tick for `occ_symbol`, or `{:error, :no_data}` if
  none has arrived yet (either no listener is running, or one is running
  but `trading_hub` hasn't broadcast anything for it) — never fabricates
  a value, matching `BlackScholes.compute/1`'s own contract shape so
  `ContractMonitor` can treat both backends identically.
  """
  @spec latest(occ_symbol()) :: {:ok, map()} | {:error, :no_data}
  def latest(occ_symbol) do
    case whereis(occ_symbol) do
      nil -> {:error, :no_data}
      pid -> GenServer.call(pid, :latest)
    end
  catch
    :exit, _ -> {:error, :no_data}
  end

  @impl true
  def init(opts) do
    occ_symbol = Keyword.fetch!(opts, :occ_symbol)
    Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, "prices:#{occ_symbol}")
    {:ok, %__MODULE__{occ_symbol: occ_symbol}}
  end

  @impl true
  def handle_call(:latest, _from, %{last_tick: nil} = state) do
    {:reply, {:error, :no_data}, state}
  end

  def handle_call(:latest, _from, %{last_tick: tick} = state) do
    {:reply, {:ok, tick}, state}
  end

  # A %TradingHub.Message{type: :price} broadcast — recognized
  # structurally, same as ContractMonitor/PriceRelay (see
  # IbPortfolio.Message's own moduledoc for why this app has no
  # compile-time TradingHub dependency). Only a message carrying at
  # least one greeks key is treated as a real option computation tick —
  # a plain stock-shaped %{bid:, ask:, last:} broadcast on the same
  # topic (which shouldn't happen if the OCC symbol convention is
  # respected, but this module doesn't enforce that itself) is ignored
  # rather than fabricating greeks from it.
  @impl true
  def handle_info(%{__struct__: TradingHub.Message, type: :price, data: data}, state) do
    case greeks_tick(data) do
      nil -> {:noreply, state}
      tick -> {:noreply, %{state | last_tick: tick}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @greeks_keys [:implied_vol, :delta, :opt_price, :gamma, :vega, :theta, :und_price]

  defp greeks_tick(data) when is_map(data) do
    if Enum.any?(@greeks_keys, &Map.has_key?(data, &1)) do
      %{
        price: Map.get(data, :opt_price),
        delta: Map.get(data, :delta),
        gamma: Map.get(data, :gamma),
        theta: Map.get(data, :theta),
        vega: Map.get(data, :vega),
        implied_vol: Map.get(data, :implied_vol),
        underlying_price: Map.get(data, :und_price)
      }
    end
  end

  defp greeks_tick(_data), do: nil
end
