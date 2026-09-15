defmodule TradingOptionsSim.SignalConnection do
  @moduledoc """
  Owns the distributed-Erlang connection to the sibling `trading_signal`
  app. Ported from `TradingLive.SignalConnection`'s identical pattern
  (see that module's own moduledoc for the full reasoning this app
  inherits unchanged) — connect/backoff/monitor-nodes skeleton mirrors
  the established, working pattern across this workspace for one app's
  live connection to another (named-node Erlang distribution, not
  libcluster/Redis).

  `trading_signal` broadcasts every computed indicator value on
  `Spec.topic(spec)` (`"signals:" <> canonical_name`, on
  `TradingSignal.PubSub`). For a `{:definition, id: id}` spec,
  `canonical_name` is `"definition:" <> id` — never the human-readable
  slug a `StrategyVersion.rules` tree actually references (e.g.
  `"ibkr_vix_vix"`) — so a caller has to resolve the slug to its `id`
  first, same as `trading_live`'s own callers.

  This module keeps the distributed-Erlang link to `trading_signal` up,
  erpc'ing `TradingSignal.Signals.request/1` (idempotently starts the
  signal's computation if not already running, and registers the caller
  as a monitored, refcounted subscriber — a plain
  `Phoenix.PubSub.subscribe/2` on the topic alone does not keep the
  signal alive) — then a `ContractMonitor` subscribes to the *resolved*
  topic directly via `Phoenix.PubSub.subscribe/2` (this module does not
  proxy or re-broadcast signal values itself, unlike
  `IbPortfolio.HubClient`'s `forward_to` pattern — a caller receives
  `{:signal, name, value}` messages in its own mailbox, where `name` is
  the canonical name, not the slug it requested with).

  On every (re)connect, broadcasts `:trading_signal_connected` on this
  app's own local `"trading_signal:connected"` topic
  (`TradingOptionsSim.PubSub`) so any already-running `ContractMonitor`
  that subscribed to a topic before the connection existed (or missed a
  reconnect window) can re-subscribe.
  """

  use GenServer
  require Logger

  defstruct signal_node: nil, connected: false, connection_attempts: 0, slug_cache: %{}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Whether the distributed-Erlang link to trading_signal is currently up."
  @spec connected? :: boolean()
  def connected? do
    GenServer.call(__MODULE__, :connected?)
  end

  @doc """
  Resolves `name` (a `StrategyVersion.rules` tree's `"signal"`/
  `"value_signal"` value — a `trading_signal` `SignalDefinition.slug`) to
  its canonical `Spec.topic/1` string, and erpc's
  `TradingSignal.Signals.request/1` for it.

  Returns `{:ok, topic}` on success — subscribe to that exact string via
  `Phoenix.PubSub.subscribe(TradingSignal.PubSub, topic)`.

  Slug -> id resolution is cached in this GenServer's own state for the
  life of the process, matching `TradingLive.SignalConnection`'s
  identical cache.
  """
  @spec request_signal(String.t()) :: {:ok, String.t()} | {:error, term()}
  def request_signal(name) do
    GenServer.call(__MODULE__, {:request_signal, name}, 10_000)
  end

  @doc """
  erpc's `TradingSignal.Regime.SessionLabel.current/0` — the current
  market regime label (`%{label:, vol_state:, trend_state:, ...}`, see
  that module's own moduledoc), a fixed single remote call rather than a
  `SignalDefinition`-backed subscription (`request_signal/1` above isn't
  the right seam for this — regime isn't a numeric rule-tree signal).

  Mirrors `trading_system`'s own `SignalHubConnection.current_regime/0`
  (confirmed by reading that module directly) — a blocking erpc, not
  `trading_live`'s non-blocking `RegimeCache`, since this app (like
  `trading_system`) has no realtime order-submission path a blocking
  call could delay; `ContractMonitor.submit_entry/2` calling this
  directly is an acceptable cost here.
  """
  @spec current_regime() :: {:ok, map()} | {:error, term()}
  def current_regime do
    GenServer.call(__MODULE__, :current_regime, 5_000)
  end

  @impl true
  def init(_opts) do
    signal_node =
      Application.get_env(:trading_options_sim, :signal_node, :trading_signal@localhost)

    send(self(), :try_connect)
    {:ok, %__MODULE__{signal_node: signal_node}}
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  def handle_call({:request_signal, _name}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:request_signal, name}, _from, state) do
    case resolve_spec(name, state) do
      {:ok, spec, state} ->
        case safe_erpc(state.signal_node, TradingSignal.Signals, :request, [spec]) do
          {:ok, _pid} ->
            {:ok, topic} =
              safe_erpc(state.signal_node, TradingSignal.Signals.Spec, :topic, [spec])

            {:reply, {:ok, topic}, state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:current_regime, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:current_regime, _from, state) do
    result = safe_erpc(state.signal_node, TradingSignal.Regime.SessionLabel, :current, [])
    {:reply, result, state}
  end

  @impl true
  def handle_info(:try_connect, state) do
    start_connect_attempt(state.signal_node)
    {:noreply, state}
  end

  def handle_info({:connect_result, result}, state) do
    case result do
      true ->
        :net_kernel.monitor_nodes(true)
        Logger.info("TradingOptionsSim.SignalConnection: connected to #{state.signal_node}")
        broadcast_connected()
        {:noreply, %{state | connected: true, connection_attempts: 0}}

      false ->
        schedule_retry(state.connection_attempts)

        {:noreply,
         %{state | connected: false, connection_attempts: state.connection_attempts + 1}}

      :ignored ->
        broadcast_connected()
        {:noreply, %{state | connected: true, connection_attempts: 0}}
    end
  end

  def handle_info({:nodedown, node}, %{signal_node: signal_node} = state)
      when node == signal_node do
    Logger.warning("TradingOptionsSim.SignalConnection: lost connection to #{signal_node}")
    send(self(), :try_connect)
    {:noreply, %{state | connected: false, connection_attempts: 0}}
  end

  def handle_info({:nodedown, _other_node}, state), do: {:noreply, state}

  def handle_info({:nodeup, node}, %{signal_node: signal_node} = state)
      when node == signal_node do
    broadcast_connected()
    {:noreply, state}
  end

  def handle_info({:nodeup, _other_node}, state), do: {:noreply, state}

  def handle_info(other, state) do
    Logger.debug(
      "TradingOptionsSim.SignalConnection: ignoring unexpected message: #{inspect(other)}"
    )

    {:noreply, state}
  end

  # :net_kernel.connect_node/1 has no timeout of its own and can block for
  # several seconds against an unreachable node — running it in a Task
  # keeps this GenServer's mailbox (and therefore connected?/0)
  # responsive the whole time.
  defp start_connect_attempt(signal_node) do
    parent = self()

    Task.start(fn ->
      send(parent, {:connect_result, :net_kernel.connect_node(signal_node)})
    end)
  end

  defp schedule_retry(attempts) do
    delay = min(1_000 * :math.pow(2, attempts), 30_000) |> round()
    Process.send_after(self(), :try_connect, delay)
  end

  defp broadcast_connected do
    Phoenix.PubSub.broadcast(
      TradingOptionsSim.PubSub,
      "trading_signal:connected",
      :trading_signal_connected
    )
  end

  # Resolves `name` to a `{:definition, id: id}` spec — this app's
  # StrategyVersion.rules trees only ever reference operator-defined
  # signals by slug, same scope cut trading_live's own resolve_spec/2
  # makes.
  defp resolve_spec(name, state) do
    case Map.fetch(state.slug_cache, name) do
      {:ok, id} ->
        {:ok, {:definition, id: id}, state}

      :error ->
        case safe_erpc(state.signal_node, TradingSignal.Signals.Spec, :parse, [name]) do
          {:ok, {:definition, id: id} = spec} ->
            {:ok, spec, put_in(state.slug_cache[name], id)}

          {:ok, _other_spec} ->
            {:error, :unsupported_signal_spec}

          {:error, _reason} = error ->
            error
        end
    end
  end

  # See TradingLive.SignalConnection.safe_erpc/4's own moduledoc for why
  # :erpc.call/5's three distinct failure shapes ({:erpc, reason},
  # {:exception, reason, _stacktrace}, a bare :exit) all need to be
  # normalized here rather than left to crash this GenServer — ported
  # verbatim, same reasoning, same real incident that motivated it
  # (trading_signal restarting mid-call must never crash the caller).
  #
  # Public (not private) solely so this exact catch behavior is directly
  # unit testable without a second distributed node.
  @doc false
  def safe_erpc(signal_node, module, function, args) do
    signal_node
    |> :erpc.call(module, function, args, 5_000)
    |> case do
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      other -> {:ok, other}
    end
  catch
    :error, {:erpc, reason} -> {:error, reason}
    :error, {:exception, reason, _stacktrace} -> {:error, reason}
    :exit, reason -> {:error, reason}
  end
end
