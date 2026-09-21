defmodule TradingOptionsSim.Pricing.UnderlyingSubscription do
  @moduledoc """
  Holds one reference-counted `trading_hub` market-data subscription for
  an underlying ticker (`"SPY"`, `"QQQ"`), so this app stops depending on
  some *other* app happening to want the same symbol.

  ## The gap this closes

  This app subscribed option contracts (`IBKRLive`, `sec_type: "OPT"`)
  but never the underlyings those options are struck on. Underlying
  prices arrived only via the `prices:all` fan-out — which carries
  whatever `trading_hub` is already subscribed to, for whatever reason.

  So a symbol was tradeable here only if a sibling app independently
  wanted it. Observed three times across restarts: `QQQ` disappeared
  from the hub and every QQQ strategy silently stopped resolving, with
  `ContractSelector` returning `{:error, :no_spot}` and the pool member
  skipped with a log line. Worse, a symbol *no* sibling tracks — `XLK`,
  `XLF` — could never work at all, no matter how many restarts.

  That is a correctness gap rather than a resilience one, and it fails
  quietly: the strategy activates with fewer monitors than intended and
  nothing surfaces it except the log.

  ## Why a process per symbol rather than a subscribe call at activation

  `TradingHub.MarketData.Manager` reference-counts by
  `{symbol, caller_tag}`, and the *last* caller to release tears down
  the real IBKR subscription. A bare subscribe at activation would have
  no corresponding release, so the app would leak subscriptions against
  IBKR's line limit every time a strategy was deactivated and
  reactivated.

  So this mirrors `IBKRLive` exactly: one process per symbol, an
  `attach/1`/`detach/1` pair, and the real `unsubscribe_symbol` in
  `terminate/2` when the depend count reaches zero. Several monitors on
  the same underlying share one subscription and one process.

  ## The caller tag is per-app, not per-monitor

  `trading_live` hit a real bug here and documented it
  (`StrategyStockMonitor`'s `@market_data_caller` comment): two
  strategies sharing a symbol collided on a single shared tag, so the
  second subscribe was a no-op and the FIRST unsubscribe released the
  tag entirely — tearing down the provider subscription out from under
  the other, still-live monitor.

  This app avoids that differently, and deliberately. The refcounting
  lives *here*, in this process's own `depend_count`, so exactly one
  subscribe and one unsubscribe ever reach the hub per symbol. A single
  app-scoped tag is therefore correct: there is never more than one
  in-flight holder of it. Do not make the tag per-strategy without also
  removing the local refcount, or the two layers will disagree.

  ## Symbol namespacing

  `trading_hub` rejects subscribing one symbol string under two
  different `sec_type`s (`{:error, {:sec_type_mismatch, ...}}`, see
  `TradingHub.IBKR.Subscriptions`). That is why options here subscribe
  under an OCC-style symbol (`"SPY   261120C00760000"`) and underlyings
  under the bare ticker (`"SPY"`). The two never collide. Keep it that
  way — reusing an OCC symbol as an underlying tag would trip that
  guard.
  """

  use GenServer

  require Logger

  defstruct [
    :symbol,
    :exchange,
    :currency,
    depend_count: 0,
    subscribed?: false,
    # Counts recovery re-issues. Exists so a test can prove the handler
    # RAN, not merely that the process survived the message -- the
    # subscribed? flag is always false where there is no hub, so it
    # cannot distinguish "re-subscribed and failed" from "never tried".
    # Also a genuine operational signal: a climbing count means the hub
    # or the Polygon socket is flapping.
    resubscribe_count: 0
  ]

  @type symbol :: String.t()

  # One tag for this whole app -- see the moduledoc on why per-symbol
  # refcounting here makes a per-strategy tag unnecessary and unsafe.
  @caller_tag "trading_options_sim:underlying"

  # :transient, not the :permanent default. Reaching depend_count 0 is a
  # deliberate {:stop, :normal, ...}, and a permanent child would be
  # RESTARTED by the DynamicSupervisor immediately after -- re-subscribing
  # a symbol nothing wants any more and leaking the IBKR line this
  # process exists to release. Caught by the "survives until the LAST
  # dependant releases" test, which saw a fresh pid registered under the
  # same symbol right after the final release.
  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :symbol)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @doc false
  def start_link(opts) do
    symbol = Keyword.fetch!(opts, :symbol)
    GenServer.start_link(__MODULE__, opts, name: via(symbol))
  end

  defp via(symbol) do
    {:via, Registry, {TradingOptionsSim.MonitorRegistry, {:underlying, symbol}}}
  end

  @doc "The running subscription holder for `symbol`, or `nil`."
  @spec whereis(symbol()) :: pid() | nil
  def whereis(symbol) do
    case Registry.lookup(TradingOptionsSim.MonitorRegistry, {:underlying, symbol}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # How long ensure/2 waits for the FIRST tick after a successful
  # subscribe, and how often it re-checks.
  #
  # Subscribing and having a price are not the same event. The hub
  # accepts the subscription immediately, but IBKR takes a moment to
  # deliver the first tick -- so a caller that resolved a contract right
  # after ensure/2 returned got {:error, :no_spot} against a
  # subscription that was perfectly healthy and priced a second later.
  # Observed live 2026-09-20: 3 of 15 versions failed to activate this
  # way, and the log read "could not resolve a listed contract
  # (:no_spot)" as though the symbol were unavailable.
  #
  # 3s is well past IBKR's observed sub-second first tick while staying
  # short enough that a genuinely dead symbol does not stall an
  # activation sweep. Waiting is skipped entirely when the subscribe
  # itself failed -- there is nothing to wait for.
  # Overridable so :test can set it to 0. There is no HubClient in test
  # (config/test.exs sets start_hub_client: false), so a tick can never
  # arrive and every ensure/2 would burn the full timeout waiting for
  # something that cannot happen -- which made previously-fast tests
  # slow enough to time out nondeterministically.
  @default_first_tick_timeout_ms 3_000
  @first_tick_poll_ms 100

  defp first_tick_timeout_ms do
    Application.get_env(
      :trading_options_sim,
      :underlying_first_tick_timeout_ms,
      @default_first_tick_timeout_ms
    )
  end

  @doc """
  Ensures `symbol` is subscribed on `trading_hub`, starting the holder
  process if needed, and registers one more dependant on it.

  Blocks until the symbol actually has a price, or the configured
  first-tick timeout elapses. That wait is the point: callers
  resolve option contracts against this symbol's spot immediately
  afterwards, and a subscription that has not yet ticked is
  indistinguishable from one that will never tick.

  Returns `{:ok, priced?}`. `false` means either the subscribe RPC
  failed (unreachable hub, a contract IBKR rejects) or no tick arrived
  in time. Deliberately not an error: a failed subscribe must not stop
  a strategy activating, for the same reason `IBKRLive` treats it as
  non-fatal. The caller surfaces it rather than crashing on it.
  """
  @spec ensure(symbol(), keyword()) :: {:ok, boolean()}
  def ensure(symbol, opts \\ []) do
    pid =
      case whereis(symbol) do
        nil ->
          spec = {__MODULE__, Keyword.put(opts, :symbol, symbol)}

          case DynamicSupervisor.start_child(TradingOptionsSim.MonitorSupervisor, spec) do
            {:ok, pid} -> pid
            {:error, {:already_started, pid}} -> pid
          end

        pid ->
          pid
      end

    case GenServer.call(pid, :attach, 15_000) do
      {:ok, true} -> {:ok, await_first_tick(symbol)}
      {:ok, false} -> {:ok, false}
    end
  end

  # Polls rather than waiting on a broadcast: this app's PriceRelay
  # subscribes to the hub's fan-out, but a caller of ensure/2 is an
  # arbitrary process (SimActivator) with no subscription of its own,
  # and adding one for a 3-second window would be more moving parts than
  # a bounded poll.
  defp await_first_tick(symbol) do
    timeout = first_tick_timeout_ms()
    deadline = System.monotonic_time(:millisecond) + timeout

    Enum.reduce_while(Stream.cycle([:tick]), false, fn _, _acc ->
      if priced?(symbol) do
        {:halt, true}
      else
        if System.monotonic_time(:millisecond) >= deadline do
          Logger.warning(
            "UnderlyingSubscription: #{symbol} subscribed but no tick within " <>
              "#{timeout}ms — callers will see :no_spot"
          )

          {:halt, false}
        else
          Process.sleep(@first_tick_poll_ms)
          {:cont, false}
        end
      end
    end)
  end

  defp priced?(symbol) do
    case call_hub(:get_last_price, [symbol]) do
      {:ok, %{last: last}} when is_number(last) and last > 0 -> true
      {:ok, %{close: close}} when is_number(close) and close > 0 -> true
      _ -> false
    end
  end

  @doc """
  Releases one dependant. The real `unsubscribe_symbol` happens in
  `terminate/2` when the count reaches zero, so a symbol shared by
  several monitors keeps its subscription until the last one lets go.

  Safe to call against an already-stopped holder.
  """
  @spec release(symbol()) :: :ok
  def release(symbol) do
    case whereis(symbol) do
      nil -> :ok
      pid -> GenServer.call(pid, :detach)
    end
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    symbol = Keyword.fetch!(opts, :symbol)

    state = %__MODULE__{
      symbol: symbol,
      exchange: Keyword.get(opts, :exchange),
      currency: Keyword.get(opts, :currency, "USD")
    }

    # Exactly once per process. :net_kernel.monitor_nodes/1 STACKS --
    # calling it again on each reconnect yields N duplicate {:nodeup, _}
    # messages per transition, and N duplicate resubscribe storms.
    :net_kernel.monitor_nodes(true)

    # Covers the Polygon in-place reconnect, which :nodeup cannot see:
    # the hub's WebSocketClient can clear its refcounts while the hub
    # NODE stays up. Subscribed here rather than at the call site so the
    # process that owns the subscription is the one that repairs it.
    Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, "system:health")

    # Subscribing in init is safe here, unlike ContractMonitor's old
    # IBKRLive startup: this is a plain hub RPC, not a start_child
    # against the same DynamicSupervisor that is currently starting this
    # process. See ContractMonitor.handle_continue/2 for that deadlock.
    {:ok, %{state | subscribed?: subscribe(state) == :ok}}
  end

  @impl true
  def handle_call(:attach, _from, state) do
    {:reply, {:ok, state.subscribed?}, %{state | depend_count: state.depend_count + 1}}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       symbol: state.symbol,
       subscribed?: state.subscribed?,
       depend_count: state.depend_count,
       resubscribe_count: state.resubscribe_count
     }, state}
  end

  def handle_call(:detach, _from, %{depend_count: count} = state) when count <= 1 do
    # terminate/2 runs before the process exits, so the unsubscribe
    # happens exactly once whether this stop is clean or abnormal.
    {:stop, :normal, :ok, %{state | depend_count: 0}}
  end

  def handle_call(:detach, _from, state) do
    {:reply, :ok, %{state | depend_count: state.depend_count - 1}}
  end

  # --- Recovery -------------------------------------------------------
  #
  # A hub-side subscription does NOT survive a trading_hub restart.
  # TradingHub.MarketData.Manager and TradingHub.Polygon.WebSocketClient
  # both refcount `symbol => MapSet of caller tags` in PROCESS STATE, so
  # when those processes die the hub stops asking the upstream for those
  # symbols.
  #
  # The failure is asymmetric and silent. This app's Phoenix.PubSub
  # topic registrations are local and survive untouched -- so we stay
  # subscribed to a topic nobody publishes to any more. No crash, no
  # error, no log line. The app looks healthy and receives nothing,
  # which is the same shape as the :no_spot and never-fires bugs this
  # app has already been bitten by.
  #
  # Supervision does not save us: a hub restart never touches this
  # process, so it is never restarted and init/1 never re-runs. Verified
  # rather than assumed -- this module previously had no handle_info
  # clauses at all.
  #
  # TWO triggers are needed and neither is sufficient alone:
  #
  #   :nodeup       covers a hub restart. Misses the Polygon in-place
  #                 reconnect, where the hub node never goes down.
  #   system:health covers Polygon's own reconnect (observed once after
  #                 a ~2h46m silent stall with the socket still
  #                 ESTABLISHED). Misses a hub restart, and can race it
  #                 -- the broadcast may fire before we have
  #                 re-subscribed to "system:health" itself.
  @impl true
  def handle_info({:nodeup, node}, state) do
    if node == hub_node() do
      Logger.info("UnderlyingSubscription: #{state.symbol} — trading_hub back up, re-subscribing")

      {:noreply, resubscribe(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  # Matched STRUCTURALLY as a plain map rather than against
  # %TradingHub.Message{}, so this app keeps no compile-time dependency
  # on trading_hub -- the same convention IbPortfolio.Message and
  # TradingSignal.HubConnection already use here.
  def handle_info(
        %{type: :health, data: %{component: :polygon_websocket, action: :resubscribe}},
        state
      ) do
    Logger.info(
      "UnderlyingSubscription: #{state.symbol} — polygon websocket re-authed, re-subscribing"
    )

    {:noreply, resubscribe(state)}
  end

  # Every other broadcast on "system:health", and anything else. A
  # catch-all is required now that this process subscribes to a topic it
  # does not fully own: an unmatched message would otherwise crash it on
  # every unrelated health broadcast. That exact failure has bitten a
  # sibling app (trading_system's connection GenServer took
  # "account:equity" broadcasts it had no clause for and crashed with
  # FunctionClauseError on every reconnect).
  def handle_info(_other, state), do: {:noreply, state}

  # Re-issue is deliberately broad rather than precise: both hub modules
  # refcount by {symbol, caller}, so re-subscribing a tag already held
  # is a harmless no-op. Tracking exactly what was lost would be more
  # code and more ways to be wrong than simply asking again.
  # get_env, NOT fetch_env!. This is read inside handle_info, so a
  # raise here kills a live subscription holder on an unrelated node
  # event -- strictly worse than the silent-stale-subscription problem
  # this recovery exists to fix. Caught by the "ignores :nodeup for any
  # other node" test, which crashed with ArgumentError in :test where
  # :hub_node is unset.
  #
  # nil never equals a real node name, so an unconfigured hub simply
  # means no :nodeup ever matches -- the same outcome as having no hub,
  # reached without taking the process down.
  defp hub_node, do: Application.get_env(:trading_options_sim, :hub_node)

  defp resubscribe(state) do
    %{
      state
      | subscribed?: subscribe(state) == :ok,
        resubscribe_count: state.resubscribe_count + 1
    }
  end

  @doc false
  def stats(pid), do: GenServer.call(pid, :stats)

  @impl true
  def terminate(_reason, %{subscribed?: true, symbol: symbol}) do
    case call_hub(:unsubscribe_symbol, [symbol, @caller_tag]) do
      :ok ->
        :ok

      other ->
        # Worth a log rather than silence: a leaked subscription consumes
        # an IBKR market-data line until trading_hub itself restarts.
        Logger.warning(
          "UnderlyingSubscription: unsubscribe for #{symbol} did not confirm: #{inspect(other)}"
        )

        :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  # `contract` is a passthrough map trading_hub does not validate beyond
  # what it needs. exchange/currency are included when the pool member
  # named them, rather than defaulting to SMART/USD silently -- matching
  # what trading_live passes for its own stock members.
  defp subscribe(state) do
    contract =
      %{sec_type: "STK", currency: state.currency}
      |> maybe_put(:primary_exchange, state.exchange)

    case call_hub(:subscribe_symbol, [state.symbol, contract, @caller_tag]) do
      :ok ->
        Logger.info("UnderlyingSubscription: subscribed #{state.symbol} on trading_hub")
        :ok

      {:error, reason} ->
        Logger.error(
          "UnderlyingSubscription: subscribe for #{state.symbol} failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Unwraps HubClient's {:ok, <remote return>} envelope so callers see
  # the remote result directly, same as ContractSelector does.
  defp call_hub(fun, args) do
    case IbPortfolio.HubClient.call_hub(
           TradingOptionsSim.HubClient,
           TradingHub.MarketData.Manager,
           fun,
           args,
           10_000
         ) do
      {:ok, remote} -> remote
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _ -> {:error, :hub_unreachable}
  end
end
