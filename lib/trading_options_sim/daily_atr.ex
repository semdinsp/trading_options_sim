defmodule TradingOptionsSim.DailyAtr do
  @moduledoc """
  The underlying's daily ATR(14), for `"atr"` risk controls
  (`ContractMonitor.risk_levels/3`). Read from trading_signal's
  `TradingSignal.Signals.DailyAtr` over `:erpc` -- the same any-symbol
  lookup trading_system's `"atr"` method uses, computed from prior
  sessions' daily bars, so the value is fixed for the session.

  Only ever `lookup/2`, never `get/2`, and with a short timeout: this is
  called from a monitor at its entry tick. `get/2` fetches on a cold
  cache, and while trading_hub restarted on 2026-10-22 it blocked for up
  to 120 s before erroring. `lookup/2` answers from the cache and, on a
  miss, starts the fetch in the background and returns `:miss`. A caller
  treats anything but `{:ok, atr}` as "no ATR" and falls back to the
  version's percents; `prewarm/1` at monitor start makes a miss at the
  first entry unlikely.

  The source module is configurable (`:daily_atr_source`) so tests run
  without a trading_signal node.
  """

  @period 14

  @doc "The daily ATR in price units, or `:unavailable` (cold cache, no node, any error)."
  @spec atr(String.t()) :: {:ok, Decimal.t()} | :unavailable
  def atr(symbol) when is_binary(symbol) do
    case source().lookup(symbol, @period) do
      {:ok, %{atr: %Decimal{} = atr}} ->
        if Decimal.compare(atr, 0) == :gt, do: {:ok, atr}, else: :unavailable

      {:ok, %{atr: atr}} when is_number(atr) and atr > 0 ->
        {:ok, Decimal.from_float(atr / 1)}

      _ ->
        :unavailable
    end
  end

  @doc "Starts trading_signal's fetch for `symbol` without waiting for it."
  @spec prewarm(String.t()) :: :ok
  def prewarm(symbol) when is_binary(symbol) do
    Task.start(fn -> source().lookup(symbol, @period) end)
    :ok
  end

  defp source,
    do: Application.get_env(:trading_options_sim, :daily_atr_source, __MODULE__.Remote)

  defmodule Remote do
    @moduledoc false
    # :erpc to trading_signal's non-blocking DailyAtr.lookup/2 with a
    # 300 ms timeout. Every failure shape (no node, timeout, exception)
    # becomes :unavailable.
    def lookup(symbol, period) do
      node = Application.get_env(:trading_options_sim, :signal_node, :trading_signal@localhost)
      :erpc.call(node, TradingSignal.Signals.DailyAtr, :lookup, [symbol, period], 300)
    catch
      _kind, _reason -> :unavailable
    end
  end
end
