defmodule TradingOptionsSim.PriceRelay do
  @moduledoc """
  Receives underlying-price ticks forwarded by `IbPortfolio.HubClient`
  (subscribed to `trading_hub`'s `"prices:*"` fan-out topic) and
  re-broadcasts each one onto this app's own **local**
  `TradingOptionsSim.PubSub` as `"prices:" <> symbol` — what
  `ContractMonitor` (§5) actually subscribes to.

  One relay for the whole app, not one per contract — mirrors how
  `trading_live`'s own monitors read ticks from the hub relayed onto a
  local bus rather than every monitor independently managing hub
  connectivity. See `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §4c.

  Also tracks the current hub connection status
  (`{:hub_connection_status, boolean}`, forwarded by `HubClient` on every
  connect/disconnect transition) so `TradingOptionsSim.StatusExtension`
  can report it without a `GenServer.call` round-trip into `HubClient`
  itself.
  """

  use GenServer

  defstruct connected?: false

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Whether the last known `HubClient` connection status was connected."
  @spec connected?() :: boolean()
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> GenServer.call(pid, :connected?)
    end
  catch
    :exit, _ -> false
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected?, state}
  end

  @impl true
  def handle_info({:hub_connection_status, connected?}, state) do
    {:noreply, %{state | connected?: connected?}}
  end

  # Every other message received while connected is a PubSub broadcast
  # HubClient forwarded verbatim from trading_hub's distributed bus —
  # only a %TradingHub.Message{type: :price} carries anything this app
  # cares about (an underlying tick); everything else (volume, orders,
  # positions, etc., all fanned out on the same "prices:*"-adjacent
  # wildcard-expanded topics HubClient subscribes to) is ignored.
  def handle_info(message, state) do
    if IbPortfolio.Message.is_message?(message) and match?(%{type: :price}, message) do
      relay_price(message)
    end

    {:noreply, state}
  end

  defp relay_price(%{symbol: symbol} = message) when is_binary(symbol) do
    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:#{symbol}", message)
  end

  # A pair-symbol price ({a, b}) or the "prices:all" fan-out marker
  # itself — neither identifies a single equity underlying this app's
  # own TargetPoolMember.symbol could match against, so there's nothing
  # useful to relay onto a per-symbol local topic.
  defp relay_price(_message), do: :ok
end
