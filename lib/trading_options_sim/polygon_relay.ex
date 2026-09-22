defmodule TradingOptionsSim.PolygonRelay do
  @moduledoc """
  Receives Polygon trade, quote and aggregate messages from
  `trading_hub` and re-broadcasts them onto this app's own **local**
  `TradingOptionsSim.PubSub`, on topics deliberately distinct from
  IBKR's.

  One relay for the whole app rather than one per symbol, mirroring
  `TradingOptionsSim.PriceRelay`'s own shape.

  ## The topics are separate on purpose — do not merge them

  `trading_hub` publishes Polygon data on
  `TradingContract.Topics.prices_polygon/1` and `volume_polygon/1`,
  never on IBKR's `prices:SYMBOL`. `TradingHub.MarketData.PolygonStreamer`'s
  moduledoc explains why: `MarketData.Manager` holds exactly one active
  provider, both providers would broadcast on the generic topic, and
  **no consumer filters on `TradingHub.Message`'s `:source` field** —
  so whichever message arrived last would silently overwrite the other
  in every consumer's cache.

  This relay preserves that separation locally. IBKR ticks reach
  `"prices:" <> symbol` via `PriceRelay`; Polygon ticks reach
  `"polygon:prices:" <> symbol` and `"polygon:volume:" <> symbol` here.
  A consumer that wants both subscribes to both and knows which is
  which. Merging them to "simplify" the consumer is the one change that
  would reintroduce a silent data-corruption bug.

  ## Dispatch is on `metadata.data_type`, never on key presence

  Trades and quotes share the `prices:polygon:SYMBOL` topic and have
  **disjoint** payloads:

      :ws_trade      data: %{last:, timestamp:}
      :ws_quote      data: %{bid:, ask:, bid_size:, ask_size:}
      :ws_aggregate  data: %{volume:, cumulative_volume:, timestamp:}

  So a handler written as `%{data: %{last: last}}` compiles, runs, and
  **silently drops every quote** — roughly 78% of traffic on a measured
  SPY capture. That is a live bug in `trading_signal`'s own
  `DefinitionSignal` at the time of writing, not a hypothetical, which
  is why every clause here matches `metadata.data_type` explicitly and
  the catch-all does nothing but ignore.

  ## Sizes may be nil

  `bid_size`/`ask_size` come from `Map.get(quote_event, "bs")` on the
  hub side and are not documented as present on every frame. They are
  passed through unchanged, including `nil`. **`nil` means unknown, not
  zero** — a consumer computing an imbalance must handle both that and
  `Decimal.div/2` raising on a zero denominator.
  """

  use GenServer

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Local topic carrying Polygon trades and quotes for `symbol`.

  Deliberately NOT `"prices:" <> symbol` — that is IBKR's, and the two
  must not be merged. See this module's own moduledoc.
  """
  @spec prices_topic(String.t()) :: String.t()
  def prices_topic(symbol), do: "polygon:prices:" <> symbol

  @doc "Local topic carrying Polygon per-minute aggregates for `symbol`."
  @spec volume_topic(String.t()) :: String.t()
  def volume_topic(symbol), do: "polygon:volume:" <> symbol

  @doc """
  Subscribes this relay to `symbol`'s hub-side Polygon topics.

  Separate from `PolygonSubscription.ensure/2`, which asks the hub to
  request the symbol from Polygon in the first place. Both are needed:
  one starts the upstream flow, the other listens for it. Calling this
  without the subscription yields a topic nobody publishes to — the
  exact silent failure `UnderlyingSubscription` exists to prevent on
  the IBKR side.
  """
  @spec watch(String.t()) :: :ok
  def watch(symbol), do: GenServer.call(__MODULE__, {:watch, symbol})

  @doc "Symbols this relay is currently listening for."
  @spec watching() :: [String.t()]
  def watching, do: GenServer.call(__MODULE__, :watching)

  @impl true
  def init(_opts) do
    {:ok, %{watching: MapSet.new()}}
  end

  @impl true
  def handle_call({:watch, symbol}, _from, state) do
    if MapSet.member?(state.watching, symbol) do
      {:reply, :ok, state}
    else
      Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, hub_prices_topic(symbol))
      Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, hub_volume_topic(symbol))
      {:reply, :ok, %{state | watching: MapSet.put(state.watching, symbol)}}
    end
  end

  def handle_call(:watching, _from, state) do
    {:reply, MapSet.to_list(state.watching), state}
  end

  # Recognized structurally (see IbPortfolio.Message's moduledoc for why
  # this app has no compile-time TradingHub dependency), and dispatched
  # on data_type rather than on which keys happen to be present.
  @impl true
  def handle_info(
        %{__struct__: TradingHub.Message, symbol: symbol, metadata: %{data_type: data_type}} =
          message,
        state
      )
      when is_binary(symbol) do
    case data_type do
      :ws_trade -> relay(prices_topic(symbol), message)
      :ws_quote -> relay(prices_topic(symbol), message)
      :ws_aggregate -> relay(volume_topic(symbol), message)
      _other -> :ok
    end

    {:noreply, state}
  end

  # Anything else: a message with no data_type, a non-Polygon broadcast
  # that reached this process, or a shape the hub adds later. Ignored
  # rather than matched loosely -- a clause that guessed from key
  # presence is exactly the bug this module's moduledoc warns about.
  def handle_info(_other, state), do: {:noreply, state}

  defp relay(topic, message) do
    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, topic, message)
  end

  # The hub-side topics, from the shared contract rather than
  # hand-written strings -- a rename on the producing side then becomes
  # a compile error here instead of a relay that silently stops
  # receiving.
  defp hub_prices_topic(symbol), do: TradingContract.Topics.prices_polygon(symbol)
  defp hub_volume_topic(symbol), do: TradingContract.Topics.volume_polygon(symbol)
end
