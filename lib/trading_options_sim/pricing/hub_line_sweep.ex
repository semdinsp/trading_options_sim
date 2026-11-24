defmodule TradingOptionsSim.Pricing.HubLineSweep do
  @moduledoc """
  Releases trading_hub option lines this app still holds but no longer
  uses. `SimReactivator` runs it a minute after every reactivation pass
  (boot, and a `MonitorSupervisor` restart).

  ## Why

  An `IBKRLive` listener releases its line in `terminate/2`. When the
  node is stopped abruptly (a restart, a kill), terminate never runs, and
  the hub keeps the line under this app's tag (`IBKRLive.caller_tag/1`).
  The tag is the same in every process, but the new process re-picks
  strikes around today's price, so it never takes over most of the old
  contracts and nothing ever releases them. Two restarts on 2026-11-23/24
  left 41 and 46 such lines (of ~160) on the hub, released by hand.

  ## How

  1. Ask the hub for every subscribed symbol
     (`TradingHub.MarketData.Manager.get_subscriptions/0`).
  2. Keep the option lines (OCC symbols) with no local `IBKRLive`
     listener.
  3. For each, release this app's tag
     (`unsubscribe_symbol(occ, caller_tag(occ))`). The hub drops only
     that tag: a line another app also holds stays up, and a line this
     app never held is a no-op there.

  The check and the release run under `IBKRLive.with_line_lock/2`, the
  same lock a listener's subscribe takes, so a listener starting for that
  contract mid-sweep either is seen (and skipped) or subscribes after the
  release.

  The hub can't say which lines carried this app's tag without reading
  its state, so the result counts lines *offered* for release; the log
  line also gives the hub's option-line count before and after.
  """

  require Logger

  alias TradingOptionsSim.Pricing.IBKRLive

  @occ ~r/^[A-Z0-9.]{1,6} *\d{6}[CP]\d{8}$/

  @type hub_call :: (atom(), list(), timeout() -> {:ok, term()} | {:error, term()})

  @doc """
  Runs the sweep. Returns `{:ok, released}`, the OCC symbols a release
  was sent for (lines only another app holds are among them, and the
  hub ignores those), or `{:error, reason}` when the hub couldn't be
  asked.

  `:call_hub` replaces the hub call (`fn function, args, timeout`), for
  tests.
  """
  @spec release_orphans(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def release_orphans(opts \\ []) do
    call = Keyword.get(opts, :call_hub, &default_call/3)

    case call.(:get_subscriptions, [], 10_000) do
      {:ok, symbols} when is_list(symbols) ->
        before = Enum.filter(symbols, &option_symbol?/1)

        released =
          before
          |> Enum.reject(&IBKRLive.whereis/1)
          |> Enum.filter(&release(&1, call))

        Logger.info(
          "HubLineSweep: sent a release of this app's tag for #{length(released)} of " <>
            "#{length(before)} hub option lines with no local listener (a no-op on the hub " <>
            "where this app held none)" <> after_count(call, released)
        )

        {:ok, released}

      other ->
        Logger.warning(
          "HubLineSweep: could not list trading_hub subscriptions: #{inspect(other)}"
        )

        {:error, other}
    end
  catch
    :exit, reason ->
      Logger.warning("HubLineSweep: trading_hub unreachable: #{inspect(reason)}")
      {:error, reason}
  end

  @doc "True for an OCC option symbol (`\"SPY   270115P00675000\"`)."
  @spec option_symbol?(term()) :: boolean()
  def option_symbol?(symbol) when is_binary(symbol), do: Regex.match?(@occ, symbol)
  def option_symbol?(_symbol), do: false

  defp release(occ, call) do
    IBKRLive.with_line_lock(occ, fn ->
      if IBKRLive.whereis(occ) do
        false
      else
        match?({:ok, _}, call.(:unsubscribe_symbol, [occ, IBKRLive.caller_tag(occ)], 5_000))
      end
    end)
  end

  defp after_count(_call, []), do: ""

  defp after_count(call, _released) do
    case call.(:get_subscriptions, [], 10_000) do
      {:ok, symbols} when is_list(symbols) ->
        " (hub option lines now #{Enum.count(symbols, &option_symbol?/1)})"

      _ ->
        ""
    end
  catch
    :exit, _reason -> ""
  end

  defp default_call(function, args, timeout) do
    IbPortfolio.HubClient.call_hub(
      TradingOptionsSim.HubClient,
      TradingHub.MarketData.Manager,
      function,
      args,
      timeout
    )
  end
end
