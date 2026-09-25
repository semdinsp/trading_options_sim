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

  ## Real `trading_hub` subscription lifecycle (per-contract, refcounted by depend count)

  On `init/1`, subscribes for real via
  `TradingHub.MarketData.Manager.subscribe_symbol/3` (over
  `IbPortfolio.HubClient.call_hub/5`), using `occ_symbol` itself as the
  `caller` tag — this is what makes this shared-per-contract listener
  safe even when trading_hub's own subscription refcounting is keyed by
  `{symbol, caller}` and not per-`ContractMonitor`: every
  `ContractMonitor` for the same contract shares this one process (see
  `whereis/1`'s own doc), so there is exactly one caller tag per real
  subscription regardless of how many monitors depend on it — the same
  bug shape `trading_live`'s own `StrategyStockMonitor` hit and fixed by
  scoping its caller tag per-`live_strategy_id` (confirmed by reading
  that code directly) simply cannot arise here, since this module IS
  the single owner trading_hub's tag identifies.

  `attach/1`/`detach/1` track how many `ContractMonitor`s currently
  depend on this listener (a plain integer, incremented on `attach/1`,
  decremented on `detach/1`) — when it reaches zero, this process
  unsubscribes from `trading_hub` for real and stops itself, rather
  than living forever after every monitor using it has deactivated
  (which would silently leak a real TWS subscription — see
  `TradingOptionsSim.SimActivator.deactivate/1`'s own moduledoc on the
  "Cleanup discipline" note this mirrors from the sibling `trading_hub`
  session's handoff on this exact risk).
  """

  use GenServer

  alias TradingOptionsSim.Pricing.ResubscribeBackoff
  require Logger

  defstruct [
    :occ_symbol,
    :contract,
    depend_count: 0,
    subscribed?: false,
    last_tick: nil,
    last_quote: nil,
    # Recovery after a trading_hub restart; see handle_info({:nodeup, _}).
    resubscribe_count: 0,
    retry_attempt: 0,
    retry_timer: nil
  ]

  @type occ_symbol :: String.t()

  @doc """
  Starts a listener for one contract's OCC-style subscription symbol
  (the string `trading_hub`'s `Subscriptions.subscribe/2` was called
  with for this contract — NOT the plain underlying ticker; see this
  module's own moduledoc on why identity is symbol-string-only today).
  `contract` is the plain map `TradingHub.MarketData.Manager.subscribe_symbol/3`
  expects (`%{sec_type: "OPT", underlying_symbol:, expiry:, strike:, right:}`)
  — `underlying_symbol` (the plain ticker, e.g. `"SPY"`) is required
  alongside the others: it's what actually gets sent as the wire
  `Contract.symbol` field, since `occ_symbol` above is purely
  `trading_hub`'s own tracking key/PubSub topic, not something TWS
  resolves an OPT contract from (confirmed via `trading_hub`'s own
  PR #105).
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
  Registers one more `ContractMonitor` as depending on this listener —
  call once, from `ContractMonitor.init/1`, right after the listener is
  started/found. Returns whether the real `trading_hub` subscription
  this listener depends on is actually live (`subscribed?: true`) or
  merely running-but-blind because the subscribe RPC failed
  (`subscribed?: false` — see `init/1`'s own doc for why that's logged,
  not fatal) — the caller, not this module, decides whether/how to
  surface that to an operator (`SimActivator.activate/1` threads it
  into its own return value for exactly this reason). See `detach/1`'s
  own doc for the matching call.
  """
  @spec attach(pid()) :: {:ok, subscribed?: boolean()}
  def attach(pid), do: GenServer.call(pid, :attach)

  @doc """
  Releases one `ContractMonitor`'s dependency on this listener — call
  once, from `ContractMonitor.terminate/2`. When the depend count
  reaches zero, this process unsubscribes from `trading_hub` for real
  and stops itself (`:normal`, not left running with nothing left
  depending on it). Safe to call on an already-stopped pid (a
  `ContractMonitor` terminating after this listener already reached
  zero some other way) — treated as already-detached, not an error.
  """
  @spec detach(pid()) :: :ok
  def detach(pid) do
    GenServer.call(pid, :detach)
  catch
    :exit, _ -> :ok
  end

  @doc """
  The last-received greeks tick for `occ_symbol`, or `{:error, :no_data}`
  if none has arrived yet (either no listener is running, or one is
  running but `trading_hub` hasn't broadcast anything for it) — never
  fabricates a value, matching `BlackScholes.compute/1`'s own contract
  shape so `ContractMonitor` can treat both backends identically.

  The returned map also carries `:quote` — the last two-sided
  `%{bid:, ask:, ...}` seen for this same contract, or `nil` if no quote
  tick has arrived. `nil` is a real state, not an error: greeks and
  quotes arrive as independent broadcasts, so a contract can have priced
  greeks and no quote yet (or, on an illiquid contract, indefinitely).
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

  # A failed real subscribe (unreachable trading_hub, test env with no
  # HubClient started, a contract trading_hub itself rejects) is logged
  # (inside subscribe_to_hub/2) but never fatal — matches trading_live's
  # own StrategyStockMonitor precedent for its identical
  # subscribe_symbol/3 call (confirmed by reading that code directly):
  # a monitor that can't establish the real data source still starts
  # and evaluates rules, it just never receives a real tick, and
  # latest/1's own existing {:error, :no_data} fail-closed behavior
  # already means a `ContractMonitor` using this listener simply never
  # fills — the same outcome a hard stop would produce, without also
  # taking down the whole monitor (and, transitively, every OTHER
  # ContractMonitor sharing this same listener) over one bad RPC.
  @impl true
  def init(opts) do
    occ_symbol = Keyword.fetch!(opts, :occ_symbol)
    contract = Keyword.fetch!(opts, :contract)

    # Exactly once per process: monitor_nodes/1 stacks, and each extra
    # call would deliver another duplicate {:nodeup, _}.
    :net_kernel.monitor_nodes(true)

    subscribed? = subscribe_to_hub(occ_symbol, contract) == :ok

    Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, "prices:#{occ_symbol}")

    state = %__MODULE__{occ_symbol: occ_symbol, contract: contract, subscribed?: subscribed?}
    {:ok, ResubscribeBackoff.after_attempt(state)}
  end

  @impl true
  def handle_call(:attach, _from, state) do
    {:reply, {:ok, subscribed?: state.subscribed?},
     %{state | depend_count: state.depend_count + 1}}
  end

  def handle_call(:detach, _from, %{depend_count: count} = state) when count <= 1 do
    # The real unsubscribe happens in terminate/2, not here — GenServer
    # guarantees terminate/2 runs before this process actually exits on
    # a {:stop, :normal, ...} reply, so there's exactly one unsubscribe
    # call regardless of whether this process stops via a clean detach
    # (this clause) or an abnormal exit (terminate/2's own doc).
    {:stop, :normal, :ok, %{state | depend_count: 0}}
  end

  def handle_call(:detach, _from, state) do
    {:reply, :ok, %{state | depend_count: state.depend_count - 1}}
  end

  def handle_call(:latest, _from, %{last_tick: nil} = state) do
    {:reply, {:error, :no_data}, state}
  end

  # The quote rides along on the greeks tick rather than being a
  # separate call: ContractMonitor prices and fills from one consistent
  # read, and a nil `quote` (no bid/ask received yet) is a real state it
  # already has to handle — see its own fill_quote/2 fallback to the
  # model mid.
  def handle_call(:latest, _from, %{last_tick: tick} = state) do
    {:reply, {:ok, Map.put(tick, :quote, state.last_quote)}, state}
  end

  # A %TradingHub.Message{type: :price} broadcast — recognized
  # structurally, same as ContractMonitor/PriceRelay (see
  # IbPortfolio.Message's own moduledoc for why this app has no
  # compile-time TradingHub dependency).
  #
  # Two genuinely different shapes arrive on this one topic, for the
  # same subscribed contract, and each is kept separately:
  #
  #   * a greeks/computation tick (`opt_price`, `delta`, ...) from
  #     trading_hub's TickOptionComputation handler -> `last_tick`
  #   * a plain quote tick (`%{bid:, bid_size:}` / `%{ask:, ask_size:}`)
  #     from its TickPrice handler -> `last_quote`
  #
  # An earlier version of this clause discarded the quote shape, calling
  # it something that "shouldn't happen if the OCC symbol convention is
  # respected." That was wrong: trading_hub's own message_handler.ex
  # documents (at its TickOptionComputation clause) that "plain
  # TickPrice/TickSize still carry bid/ask/last on the option contract
  # itself — greeks only ever arrive via this message," i.e. both shapes
  # are expected on exactly this contract's topic. The quote is the only
  # two-sided price this app ever sees, so it's what ContractMonitor
  # needs to fill at the touch instead of at an untradeable model mid.
  #
  # Bid and ask arrive as separate ticks, so each is merged into the
  # existing quote rather than replacing it — an ask tick must not
  # erase the bid that came before it.
  @impl true
  def handle_info(%{__struct__: TradingHub.Message, type: :price, data: data} = message, state) do
    at = message_time(message)

    state =
      case greeks_tick(data) do
        nil -> state
        tick -> %{state | last_tick: Map.put(tick, :at, at)}
      end

    case quote_tick(data, at) do
      nil ->
        {:noreply, state}

      quote_fields ->
        {:noreply, %{state | last_quote: merge_quote(state.last_quote, quote_fields)}}
    end
  end

  # A trading_hub restart drops every subscription it held, and nothing
  # restarts this process, so without this the option's ticks stop for
  # good and the monitor goes stale. That happened on 2026-09-25: 30 of 31
  # listeners were stale until the node was restarted. Re-subscribe when
  # the hub node comes back, and keep retrying until it accepts.
  def handle_info({:nodeup, node}, state) do
    if node == Application.get_env(:trading_options_sim, :hub_node) do
      Logger.info("IBKRLive: #{state.occ_symbol} -- trading_hub back up, re-subscribing")
      {:noreply, state |> resubscribe() |> ResubscribeBackoff.after_attempt()}
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  def handle_info(:retry_subscribe, state) do
    state = %{state | retry_timer: nil}
    {:noreply, state |> resubscribe() |> ResubscribeBackoff.after_attempt()}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # The hub refcounts by {symbol, caller}, so re-subscribing a caller
  # tag it already holds is a harmless no-op.
  defp resubscribe(state) do
    %{
      state
      | subscribed?: subscribe_to_hub(state.occ_symbol, state.contract) == :ok,
        resubscribe_count: state.resubscribe_count + 1
    }
  end

  # The single place this process ever unsubscribes from trading_hub —
  # GenServer guarantees this runs before the process actually exits,
  # whether that exit is the clean {:stop, :normal, ...} reply
  # handle_call(:detach, ...) sends on reaching depend_count 0, or an
  # abnormal exit (a supervisor kill, an unhandled crash) while
  # depend_count was still > 0. Without this, the abnormal-exit case
  # would leak the real trading_hub subscription forever — the exact
  # "Cleanup discipline" risk SimActivator.deactivate/1's own moduledoc
  # already documents inheriting from the sibling trading_hub session's
  # handoff. Skipped entirely when the initial subscribe itself never
  # succeeded (subscribed?: false, see init/1) — nothing real to
  # release, and calling unsubscribe_symbol/2 for a caller tag that was
  # never actually registered would just be a wasted RPC (still
  # harmless, trading_hub documents it idempotent, but there's no
  # reason to make it either).
  @impl true
  def terminate(_reason, %{subscribed?: true} = state) do
    unsubscribe_from_hub(state.occ_symbol)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @doc false
  def caller_tag(occ_symbol), do: occ_symbol

  # Every failure log includes the contract map that was sent, so a
  # rejected or failed subscribe can be diagnosed from the log alone.
  defp subscribe_to_hub(occ_symbol, contract) do
    case IbPortfolio.HubClient.call_hub(
           TradingOptionsSim.HubClient,
           TradingHub.MarketData.Manager,
           :subscribe_symbol,
           [occ_symbol, contract, caller_tag(occ_symbol)],
           5_000
         ) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        Logger.error(
          "IBKRLive: subscribe_symbol(#{occ_symbol}) rejected by trading_hub: #{inspect(reason)}, " <>
            "contract: #{inspect(contract)}"
        )

        {:error, reason}

      {:error, reason} ->
        Logger.error(
          "IBKRLive: subscribe_symbol(#{occ_symbol}) RPC failed: #{inspect(reason)}, " <>
            "contract: #{inspect(contract)}"
        )

        {:error, reason}
    end
  catch
    # HubClient isn't started in test env (config :start_hub_client, false)
    # and GenServer.call/2 against an unregistered name exits (:noproc)
    # rather than returning — caught here so an unreachable/absent
    # HubClient degrades the same as any other subscribe failure (logged,
    # non-fatal) instead of crashing this listener's init/1.
    :exit, reason ->
      Logger.error(
        "IBKRLive: subscribe_symbol(#{occ_symbol}) HubClient unreachable: #{inspect(reason)}, " <>
          "contract: #{inspect(contract)}"
      )

      {:error, reason}
  end

  # Best-effort — see terminate/2's own comment on why a failed real
  # unsubscribe here still lets this process stop (retrying against an
  # unreachable trading_hub isn't something this process can act on
  # differently; a leaked subscription from a genuinely dropped node is
  # an accepted, already-documented risk, not one this call can fully
  # close on its own).
  defp unsubscribe_from_hub(occ_symbol) do
    case IbPortfolio.HubClient.call_hub(
           TradingOptionsSim.HubClient,
           TradingHub.MarketData.Manager,
           :unsubscribe_symbol,
           [occ_symbol, caller_tag(occ_symbol)],
           5_000
         ) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "IBKRLive: unsubscribe_symbol(#{occ_symbol}) RPC failed: #{inspect(reason)} — stopping anyway"
        )

        :ok
    end
  catch
    # See subscribe_to_hub/2's own catch clause — same unreachable-HubClient
    # risk, same "stop anyway" posture terminate/2 already documents.
    :exit, reason ->
      Logger.warning(
        "IBKRLive: unsubscribe_symbol(#{occ_symbol}) HubClient unreachable: #{inspect(reason)} — stopping anyway"
      )

      :ok
  end

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

  @quote_keys [:bid, :ask, :bid_size, :ask_size]

  # A plain TickPrice-derived quote broadcast. `delayed: true` is
  # carried through rather than filtered: trading_hub sets it when TWS
  # falls back to delayed ticks (no real-time entitlement, or outside
  # market hours — see its own TickPrice handler), and a delayed quote
  # is still a real two-sided market, just a stale one. Recording the
  # flag lets a consumer decide; silently dropping the quote would send
  # this app back to model-mid fills exactly when spreads matter most.
  defp quote_tick(data, at) when is_map(data) do
    if Enum.any?(@quote_keys, &Map.has_key?(data, &1)) do
      data
      |> Map.take(@quote_keys ++ [:delayed])
      |> Map.put(:received_at, at)
    end
  end

  defp quote_tick(_data, _at), do: nil

  # When a tick or quote was produced, for ContractMonitor's staleness
  # gate: the hub's own Message.timestamp, falling back to receive time
  # when absent. Same clock convention as PolygonFeatures, so data that
  # arrives late does not read as fresh.
  defp message_time(%{timestamp: %DateTime{} = ts}), do: ts
  defp message_time(_message), do: DateTime.utc_now()

  defp merge_quote(nil, quote_fields), do: quote_fields
  defp merge_quote(existing, quote_fields), do: Map.merge(existing, quote_fields)
end
