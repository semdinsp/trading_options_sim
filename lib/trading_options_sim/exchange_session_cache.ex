defmodule TradingOptionsSim.ExchangeSessionCache do
  @moduledoc """
  In-memory cache of `exchange => TradingCore.MarketHours.Session` —
  ported near-verbatim from `TradingLive.ExchangeSessionCache` (see
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §5c). Avoids a DB round trip on
  every tick of every running `ContractMonitor` — the same
  pool-exhaustion risk `trading_live`'s own cache was written to fix
  (a burst of ticks driving an uncached per-tick query well past this
  app's own `pool_size`).

  A GenServer owns one ETS table (`:public`, `:read_concurrency` — reads
  never touch the GenServer process) and repopulates it from the DB at
  init and every `@refresh_interval_ms` thereafter. `fetch/1` reads ETS
  directly. A cache miss falls back to a direct, uncached DB query rather
  than returning stale `nil` and failing a check closed for an exchange
  that genuinely has a mapped session.

  `fetch/1` always queries the DB directly in `:test` (see
  `config :trading_options_sim, :exchange_session_cache_enabled, false`)
  — every test seeds its own `ExchangeSession`/`ExchangeTradingHours`
  fixtures inside its own sandboxed transaction and expects
  `ContractMonitor`'s session check to see them immediately, which a
  singleton cache populated once at application boot never would.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias TradingOptionsSim.Repo
  alias TradingOptionsSim.Sim.ExchangeSession
  alias TradingOptionsSim.Sim.ExchangeTradingHours

  @table __MODULE__
  @refresh_interval_ms :timer.minutes(5)

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  The `TradingCore.MarketHours.Session` mapped to `exchange`, or `nil` if
  none is mapped. Reads ETS directly — never blocks on the cache's own
  GenServer. Falls back to a direct DB query on a cache miss.
  """
  @spec fetch(String.t()) :: TradingCore.MarketHours.Session.t() | nil
  def fetch(exchange) do
    if Application.get_env(:trading_options_sim, :exchange_session_cache_enabled, true) do
      case :ets.whereis(@table) do
        :undefined -> query_session(exchange)
        _tid -> fetch_from_ets(exchange)
      end
    else
      query_session(exchange)
    end
  end

  defp fetch_from_ets(exchange) do
    case :ets.lookup(@table, exchange) do
      [{^exchange, session}] -> session
      [] -> nil
    end
  end

  @doc "Forces an immediate, synchronous refresh from the DB — for tests only."
  @spec refresh_now() :: :ok
  def refresh_now do
    GenServer.call(__MODULE__, :refresh_now)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    if Application.get_env(:trading_options_sim, :exchange_session_cache_enabled, true) do
      refresh()
      schedule_refresh()
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    refresh()
    schedule_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh_now, _from, state) do
    refresh()
    {:reply, :ok, state}
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  defp refresh do
    mappings = all_sessions()
    :ets.delete_all_objects(@table)
    :ets.insert(@table, mappings)
    Logger.debug("ExchangeSessionCache: refreshed #{length(mappings)} exchange session mappings")
  rescue
    error ->
      Logger.error(
        "ExchangeSessionCache: refresh failed, keeping stale cache: " <> inspect(error)
      )
  end

  defp all_sessions do
    query =
      from es in ExchangeSession,
        join: eth in assoc(es, :exchange_trading_hours),
        select: {es.exchange, eth}

    query
    |> Repo.all()
    |> Enum.map(fn {exchange, row} -> {exchange, ExchangeTradingHours.to_session(row)} end)
  end

  defp query_session(exchange) do
    query =
      from es in ExchangeSession,
        join: eth in assoc(es, :exchange_trading_hours),
        where: es.exchange == ^exchange,
        select: eth

    case Repo.one(query) do
      nil -> nil
      row -> ExchangeTradingHours.to_session(row)
    end
  end
end
