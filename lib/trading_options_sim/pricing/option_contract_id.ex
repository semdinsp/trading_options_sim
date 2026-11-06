defmodule TradingOptionsSim.Pricing.OptionContractId do
  @moduledoc """
  Pins an option contract to IBKR's `con_id` before `IBKRLive` subscribes.

  `IBKRLive` used to subscribe with only a description:
  `%{sec_type: "OPT", underlying_symbol:, expiry:, strike:, right:}`. For some
  SPY and QQQ strikes more than one listed contract matches that description,
  and TWS rejects the request with error 200 ("The contract description
  specified for QQQ is ambiguous; you must specify the multiplier or trading
  class"). trading_hub's log showed this daily from at least 2026-10-28
  (107 SPY and 70 QQQ rejections), so those contracts never streamed. The
  monitor still started, and got no ticks.

  `pin/2` asks trading_hub's `ContractResolver` for the `con_id`, narrowed to
  the standard US equity option class (multiplier `"100"`, trading class =
  the underlying ticker), and adds `contract_id`, `multiplier` and
  `trading_class` to the contract map.

  ## Older hubs

  `resolve/5` (with `multiplier:`/`trading_class:`) arrives in trading_hub
  PR #166. Until a hub has it, `pin/2` uses `resolve/4`. That cannot narrow
  the match, so for an ambiguous strike it returns `:ambiguous`. In that
  case only, the contract is still subscribed, without a `contract_id` but
  with `multiplier: "100"`, which the hub already passes to TWS and which
  may be enough on its own. Every other failure stops the subscribe: an
  unpinned contract that TWS may refuse is not sent blind.
  """

  @multiplier "100"

  # A resolve miss takes IBKR's full 10 s (it never replies for an unknown
  # contract); 15 s lets that answer arrive instead of an RPC timeout. See
  # ContractSelector's @hub_call_timeout_ms.
  @resolve_timeout_ms 15_000

  @resolver TradingHub.IBKR.ContractResolver

  @typedoc "Calls `module.fun(args)` on trading_hub and returns its result."
  @type hub_call :: (module(), atom(), list(), timeout() -> term())

  @doc """
  Returns `{:ok, contract}` with `contract_id`, `multiplier` and
  `trading_class` set, `{:ok, contract}` with only `multiplier` set (an older
  hub that reports the description as ambiguous; see the moduledoc), or
  `{:error, reason}` when the contract should not be subscribed.

  A contract that already has a `contract_id` is returned unchanged.
  `hub_call` is replaceable for tests.
  """
  @spec pin(map(), hub_call()) :: {:ok, map()} | {:error, term()}
  def pin(contract, hub_call \\ &default_hub_call/4)

  def pin(%{contract_id: id} = contract, _hub_call) when is_integer(id), do: {:ok, contract}

  def pin(
        %{underlying_symbol: symbol, expiry: expiry, strike: strike, right: right} = contract,
        hub_call
      ) do
    narrowed = Map.merge(contract, %{multiplier: @multiplier, trading_class: symbol})
    base = [symbol, expiry, strike, right]

    if resolve5?(hub_call) do
      opts = [multiplier: @multiplier, trading_class: symbol]

      case hub_call.(@resolver, :resolve, base ++ [opts], @resolve_timeout_ms) do
        {:ok, con_id} when is_integer(con_id) -> {:ok, Map.put(narrowed, :contract_id, con_id)}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected, other}}
      end
    else
      case hub_call.(@resolver, :resolve, base, @resolve_timeout_ms) do
        {:ok, con_id} when is_integer(con_id) ->
          {:ok, Map.put(narrowed, :contract_id, con_id)}

        {:error, :ambiguous} ->
          {:ok, Map.put(contract, :multiplier, @multiplier)}

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, {:unexpected, other}}
      end
    end
  end

  def pin(contract, _hub_call), do: {:error, {:incomplete_contract, contract}}

  # Asked each time rather than cached, so a hub that gains resolve/5
  # (PR #166 deployed) is used from the next subscribe without a restart
  # here. HubClient's error envelope cannot tell an UndefinedFunctionError
  # apart from any other RPC failure, so ask for the export directly.
  defp resolve5?(hub_call) do
    hub_call.(:erlang, :function_exported, [@resolver, :resolve, 5], 5_000) == true
  end

  defp default_hub_call(module, fun, args, timeout) do
    case IbPortfolio.HubClient.call_hub(TradingOptionsSim.HubClient, module, fun, args, timeout) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  catch
    # HubClient isn't started in test env, and an unregistered name exits.
    :exit, reason -> {:error, {:hub_unreachable, reason}}
  end
end
