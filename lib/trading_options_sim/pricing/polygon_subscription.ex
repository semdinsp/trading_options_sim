defmodule TradingOptionsSim.Pricing.PolygonSubscription do
  @moduledoc """
  Holds one reference-counted `trading_hub` **Polygon** market-data
  subscription for an underlying ticker, so this app can read volume and
  a real two-sided quote on the underlying.

  Deliberately a near-twin of
  `TradingOptionsSim.Pricing.UnderlyingSubscription` rather than a
  generalisation of it. See "Why two modules" below.

  ## What this is for, and what it is NOT for

  Underlying data only. **Option contracts stay on IBKR** — see
  `handoff_prompts/2026-09-21-polygon-underlying/0_DECISION.md`.
  `TradingHub.Polygon.WebSocketClient` subscribes `T.`/`Q.`/`AM.`, the
  equities cluster; it has no option handling at all, and Polygon
  options are a separately-priced feed. So this changes nothing about
  how fills are priced.

  What it adds is data this app could not previously see:

    * **Volume** — `AM.*` aggregates carry `volume` and
      `cumulative_volume`. No strategy could reference volume before,
      because it never arrived.
    * **A real two-sided quote on the underlying** — IBKR returns
      `bid: -1.0` / `ask: -1.0` outside session hours, so only `last`
      was usable then.

  ## Why two modules rather than one parameterised by provider

  The two hub APIs differ in arity and in semantics:

      # IBKR   — contract disambiguates multi-listed symbols
      MarketData.Manager.subscribe_symbol(symbol, contract, caller_tag)

      # Polygon — no contract; the symbol IS the identity
      Polygon.WebSocketClient.subscribe_symbol(symbol, caller_tag)

  A shared module would need a provider branch in `subscribe`,
  `terminate` and the health handler, which is most of the module. The
  duplication here is ~60 lines of near-identical lifecycle code, and
  the alternative is a conditional threaded through every function. The
  handoff's own instruction is to add alongside rather than refactor a
  working IBKR path until the second one has proven its shape.

  ## Reference counting and recovery

  Same as the IBKR twin, for the same reasons:

    * One process per symbol; `ensure/2` attaches a dependant,
      `release/1` detaches. The real `unsubscribe_symbol` happens in
      `terminate/2` at zero dependants, so several strategies on one
      symbol share a single subscription.
    * `child_spec` is `:transient`. At the `:permanent` default the
      DynamicSupervisor restarts the holder immediately after its
      deliberate `{:stop, :normal}` — re-subscribing a symbol nothing
      wants and leaking the very subscription this process exists to
      release. That bug was already hit once in the IBKR twin.
    * Recovery on both `{:nodeup, hub_node}` (a hub restart) and the
      `system:health` `:resubscribe` broadcast (Polygon's own re-auth,
      where the hub node never goes down). Neither trigger is
      sufficient alone.

  Polygon's `subscribe_symbol/2` is safe to call before the socket
  authenticates: the refcount is recorded immediately and the wire
  frame is sent once auth completes. So a subscribe during a reconnect
  window is a no-op rather than an error.
  """

  use GenServer

  require Logger

  defstruct [:symbol, depend_count: 0, subscribed?: false, resubscribe_count: 0]

  @type symbol :: String.t()

  # One tag for this whole app. Per-symbol refcounting lives here, so
  # exactly one subscribe and one unsubscribe ever reach the hub per
  # symbol -- which is what makes a single app-scoped tag correct. Do
  # not make this per-strategy without also removing the local
  # refcount, or the two layers will disagree. (trading_live hit that
  # bug: a shared tag meant the FIRST unsubscribe tore down the
  # subscription under another still-live monitor.)
  @caller_tag "trading_options_sim:polygon"

  @default_first_tick_timeout_ms 3_000
  @first_tick_poll_ms 100

  # Overridable so :test can set it to 0. There is no HubClient in test
  # (start_hub_client: false), so a tick can never arrive and every
  # ensure/2 would burn the full timeout waiting for something
  # impossible -- which in the IBKR twin made unrelated tests slow
  # enough to time out nondeterministically.
  defp first_tick_timeout_ms do
    Application.get_env(
      :trading_options_sim,
      :polygon_first_tick_timeout_ms,
      @default_first_tick_timeout_ms
    )
  end

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
    {:via, Registry, {TradingOptionsSim.MonitorRegistry, {:polygon, symbol}}}
  end

  @doc "The running Polygon subscription holder for `symbol`, or `nil`."
  @spec whereis(symbol()) :: pid() | nil
  def whereis(symbol) do
    case Registry.lookup(TradingOptionsSim.MonitorRegistry, {:polygon, symbol}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Ensures `symbol` is subscribed on trading_hub's Polygon feed, starting
  the holder if needed, and registers one more dependant.

  Blocks until the symbol has actually ticked, or the configured
  first-tick timeout elapses. Returns `{:ok, priced?}`; `false` means
  either the subscribe RPC failed or no tick arrived in time.

  Deliberately not an error: a failed subscribe must not stop a caller
  proceeding, for the same reason the IBKR twin treats it as non-fatal.
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

  @doc """
  Releases one dependant. The real `unsubscribe_symbol` happens in
  `terminate/2` at zero, so a symbol several callers still need keeps
  its subscription. Safe against an already-stopped holder.
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

  @doc false
  def stats(pid), do: GenServer.call(pid, :stats)

  @impl true
  def init(opts) do
    symbol = Keyword.fetch!(opts, :symbol)

    # Exactly once per process -- monitor_nodes/1 STACKS, so calling it
    # per reconnect yields N duplicate {:nodeup, _} messages and N
    # duplicate resubscribe storms.
    :net_kernel.monitor_nodes(true)

    # Covers Polygon's in-place reconnect, which :nodeup cannot see: the
    # WebSocketClient can clear its refcounts while the hub NODE stays
    # up. Observed on the hub side once after a ~2h46m silent stall with
    # the socket still ESTABLISHED.
    Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, "system:health")

    state = %__MODULE__{symbol: symbol}
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
    {:stop, :normal, :ok, %{state | depend_count: 0}}
  end

  def handle_call(:detach, _from, state) do
    {:reply, :ok, %{state | depend_count: state.depend_count - 1}}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    if node == hub_node() do
      Logger.info("PolygonSubscription: #{state.symbol} — trading_hub back up, re-subscribing")
      {:noreply, resubscribe(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  # Matched structurally as a plain map, not against %TradingHub.Message{},
  # so this app keeps no compile-time dependency on trading_hub.
  def handle_info(
        %{type: :health, data: %{component: :polygon_websocket, action: :resubscribe}},
        state
      ) do
    Logger.info("PolygonSubscription: #{state.symbol} — polygon re-authed, re-subscribing")
    {:noreply, resubscribe(state)}
  end

  # The hub rejected our symbol and has already dropped its own refcount
  # for it, so we are no longer subscribed. Clearing the flag keeps
  # stats/terminate honest; the next :resubscribe or :nodeup retries.
  def handle_info(
        %{
          type: :health,
          data: %{component: :polygon_websocket, status: :subscribe_rejected, symbol: symbol}
        },
        %{symbol: symbol} = state
      ) do
    Logger.warning("PolygonSubscription: #{symbol} — subscribe rejected by Polygon")
    {:noreply, %{state | subscribed?: false}}
  end

  # Required, not defensive padding: this process subscribes to
  # "system:health", a topic it does not own, so it WILL receive
  # broadcasts it has no specific clause for. trading_system's
  # connection GenServer crashed with FunctionClauseError on every
  # reconnect after taking "account:equity" broadcasts it had no clause
  # for.
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{subscribed?: true, symbol: symbol}) do
    case call_hub(:unsubscribe_symbol, [symbol, @caller_tag]) do
      :ok ->
        :ok

      other ->
        Logger.warning(
          "PolygonSubscription: unsubscribe for #{symbol} did not confirm: #{inspect(other)}"
        )

        :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  # Broad rather than precise: the hub refcounts by {symbol, caller}, so
  # re-subscribing a tag already held is a harmless no-op. Tracking
  # exactly what was lost would be more code and more ways to be wrong.
  defp resubscribe(state) do
    %{
      state
      | subscribed?: subscribe(state) == :ok,
        resubscribe_count: state.resubscribe_count + 1
    }
  end

  defp subscribe(state) do
    case call_hub(:subscribe_symbol, [state.symbol, @caller_tag]) do
      :ok ->
        Logger.info("PolygonSubscription: subscribed #{state.symbol} on trading_hub (polygon)")
        :ok

      {:error, reason} ->
        Logger.error(
          "PolygonSubscription: subscribe for #{state.symbol} failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp await_first_tick(symbol) do
    timeout = first_tick_timeout_ms()
    deadline = System.monotonic_time(:millisecond) + timeout

    Enum.reduce_while(Stream.cycle([:tick]), false, fn _, _acc ->
      cond do
        ticked?(symbol) ->
          {:halt, true}

        System.monotonic_time(:millisecond) >= deadline ->
          Logger.warning(
            "PolygonSubscription: #{symbol} subscribed but no tick within #{timeout}ms"
          )

          {:halt, false}

        true ->
          Process.sleep(@first_tick_poll_ms)
          {:cont, false}
      end
    end)
  end

  # The hub's Polygon client exposes no per-symbol price read, so
  # "has it ticked" is answered by the subscription list rather than by
  # a value. Weaker than the IBKR twin's get_last_price check, and
  # honestly so: it confirms the hub accepted the symbol, not that data
  # is flowing. Callers that need a value must read the relayed topic.
  defp ticked?(symbol) do
    case call_hub(:get_subscriptions, []) do
      symbols when is_list(symbols) -> symbol in symbols
      _ -> false
    end
  end

  defp hub_node, do: Application.get_env(:trading_options_sim, :hub_node)

  # get_env, NOT fetch_env! -- this is read inside handle_info, and a
  # raise there would kill a live subscription holder on an unrelated
  # node event. nil never equals a real node name.
  defp call_hub(fun, args) do
    case IbPortfolio.HubClient.call_hub(
           TradingOptionsSim.HubClient,
           TradingHub.Polygon.WebSocketClient,
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
