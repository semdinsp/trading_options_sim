defmodule TradingOptionsSim.MarketContextSignals do
  @moduledoc """
  Holds the latest value of every trading_signal signal that
  `TradingCore.MarketContext` stamps on fills (dealer gamma, return
  since prior close, noise band, opening range), so `ContractMonitor`
  can build a `market_context` without a remote call or a subscription
  of its own.

  One process subscribes to every slug in
  `TradingCore.MarketContext.signal_slugs/0`, resolving each through
  `SignalBus.request/1` exactly as `ContractMonitor` does for its rule
  signals, and re-resolving on every `:trading_signal_connected` (a
  slug's uuid can change if its definition is recreated). Each
  `{:signal, canonical, value}` is stored with the time it arrived;
  `{:signal_cleared, canonical}` removes it. `TradingCore.MarketContext`
  then drops anything older than its age limits, so a feed that goes
  quiet without clearing is omitted rather than stamped stale.

  Values live in a public ETS table, read directly by `values/0`, so a
  fill never waits on this process. Recording only: nothing here gates
  a trade.
  """

  use GenServer
  require Logger

  alias TradingOptionsSim.SignalBus

  @table __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  `%{slug => {value, received_at}}` for every signal currently held, in
  the shape `TradingCore.MarketContext.build/3` takes. Empty if the
  process hasn't started. Never blocks.
  """
  @spec values() :: %{String.t() => {term(), DateTime.t()}}
  def values do
    case :ets.whereis(@table) do
      :undefined -> %{}
      _tid -> @table |> :ets.tab2list() |> Map.new()
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, "trading_signal:connected")
    {:ok, %{canonical_to_slug: subscribe_all()}}
  end

  @impl true
  def handle_info(:trading_signal_connected, state) do
    {:noreply, %{state | canonical_to_slug: Map.merge(state.canonical_to_slug, subscribe_all())}}
  end

  def handle_info({:signal, canonical, value}, state) do
    case Map.fetch(state.canonical_to_slug, canonical) do
      {:ok, slug} -> :ets.insert(@table, {slug, {value, DateTime.utc_now()}})
      :error -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:signal_cleared, canonical}, state) do
    case Map.fetch(state.canonical_to_slug, canonical) do
      {:ok, slug} -> :ets.delete(@table, slug)
      :error -> :ok
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # %{canonical_name => slug} for every slug that resolved. A slug that
  # can't be resolved yet (trading_signal down, slug not deployed) is
  # retried on the next :trading_signal_connected.
  defp subscribe_all do
    Enum.reduce(TradingCore.MarketContext.signal_slugs(), %{}, fn slug, acc ->
      case SignalBus.request(slug) do
        {:ok, topic} ->
          subscribe_once(topic)
          Map.put(acc, String.trim_leading(topic, "signals:"), slug)

        {:error, reason} ->
          Logger.debug("MarketContextSignals: could not request #{slug}: #{inspect(reason)}")
          acc
      end
    end)
  catch
    :error, %ArgumentError{} -> %{}
    :exit, _reason -> %{}
  end

  defp subscribe_once(topic) do
    unless topic in Registry.keys(TradingSignal.PubSub, self()) do
      Phoenix.PubSub.subscribe(TradingSignal.PubSub, topic)
    end
  end
end
