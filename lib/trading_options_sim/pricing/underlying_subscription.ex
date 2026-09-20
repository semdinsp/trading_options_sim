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

  defstruct [:symbol, :exchange, :currency, depend_count: 0, subscribed?: false]

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

  @doc """
  Ensures `symbol` is subscribed on `trading_hub`, starting the holder
  process if needed, and registers one more dependant on it.

  Returns `{:ok, subscribed?}` — `subscribed?` is `false` when the
  process is running but the real subscribe RPC failed (an unreachable
  hub, a contract IBKR rejects). Deliberately not an error: a failed
  subscribe must not stop a strategy activating, for the same reason
  `IBKRLive` treats it as non-fatal. The caller surfaces it instead of
  crashing on it.
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

    GenServer.call(pid, :attach, 15_000)
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

  def handle_call(:detach, _from, %{depend_count: count} = state) when count <= 1 do
    # terminate/2 runs before the process exits, so the unsubscribe
    # happens exactly once whether this stop is clean or abnormal.
    {:stop, :normal, :ok, %{state | depend_count: 0}}
  end

  def handle_call(:detach, _from, state) do
    {:reply, :ok, %{state | depend_count: state.depend_count - 1}}
  end

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
