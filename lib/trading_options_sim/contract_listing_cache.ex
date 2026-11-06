defmodule TradingOptionsSim.ContractListingCache do
  @moduledoc """
  Remembers, for an hour, that IBKR does not list an option contract, so
  `ContractSelector` does not ask trading_hub again.

  At a restart the reactivator activates every version, and each one
  probes its own strike/expiry candidates. Versions on the same
  underlying probe the same strikes, so on 2026-11-06 about ten XLE
  versions asked for the same unlisted 62C/59P/57P/62P strikes: 38 TWS
  "No security definition" errors in 18 seconds. trading_hub's
  `ContractResolver` caches hits but not misses, so every repeat was a
  new `reqContractDetails` to TWS.

  Only definitive misses (`:not_found`, `:ambiguous`) are kept. A hub
  that did not answer (timeout, not connected) taught nothing and is
  never cached, and hits are already cached by the hub. The hour is a
  safety margin: listings change overnight, not within a restart, and
  an entry expires before it could hide a strike listed the next day.

  The ETS table is public and read by callers directly; this process
  only owns it, so it outlives any caller.
  """

  use GenServer

  @table __MODULE__
  @ttl_ms 60 * 60 * 1000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc """
  Wraps a `resolver` (`symbol, expiry, strike, right -> result`) so a
  definitive miss is answered from the cache for the next hour. Without
  the table (this process not started) it calls `resolver` unchanged.
  """
  @spec cached((String.t(), String.t(), number(), String.t() -> term())) ::
          (String.t(), String.t(), number(), String.t() -> term())
  def cached(resolver) do
    fn symbol, expiry, strike, right ->
      key = {symbol, expiry, normalize(strike), right}

      case lookup(key) do
        {:hit, miss} ->
          miss

        :none ->
          result = resolver.(symbol, expiry, strike, right)
          maybe_store(key, result)
          result
      end
    end
  end

  @doc false
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  defp lookup(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, miss, expires_at}] when expires_at > now -> {:hit, miss}
      _ -> :none
    end
  rescue
    ArgumentError -> :none
  end

  defp maybe_store(key, {:error, reason} = miss) when reason in [:not_found, :ambiguous] do
    :ets.insert(@table, {key, miss, System.monotonic_time(:millisecond) + ttl_ms()})
  rescue
    ArgumentError -> :ok
  end

  defp maybe_store(_key, _result), do: :ok

  defp ttl_ms,
    do: Application.get_env(:trading_options_sim, :contract_listing_cache_ttl_ms, @ttl_ms)

  # 62, 62.0 and Decimal 62.00 are the same strike.
  defp normalize(%Decimal{} = d), do: d |> Decimal.normalize() |> Decimal.to_string(:normal)
  defp normalize(n) when is_integer(n), do: n |> Decimal.new() |> normalize()
  defp normalize(n) when is_float(n), do: n |> Decimal.from_float() |> normalize()
  defp normalize(other), do: other
end
