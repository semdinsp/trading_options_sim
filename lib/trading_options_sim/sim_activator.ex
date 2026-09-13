defmodule TradingOptionsSim.SimActivator do
  @moduledoc """
  Starts `ContractMonitor`s for a `StrategyVersion`'s target pool
  members, mirroring `TradingLive.StrategyActivator`'s
  `start_for_member/2` shape. See `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §6.

  ## v1 contract resolution

  `option_leg_config`'s `"strike_selection"`/`"expiry_selection"` fields
  (`fixed_delta`/`dte_target`/etc — see plan §2) describe how a real
  options-chain-aware resolver would eventually pick a contract, but no
  such resolver exists yet (needs `trading_hub`'s live options chain
  data, not yet frame-verified — see plan §5a's update note). v1 only
  supports `"fixed_strike"`/`"fixed"` selection, requiring
  `option_leg_config` to carry the exact `"strike"`/`"expiry"` to trade
  — `activate/1` returns `{:error, :unsupported_leg_config}` for
  anything else rather than guessing a contract. This is a real,
  deliberate gap, not an oversight: extend this module (not
  `ContractMonitor`) once delta/DTE-target resolution has real chain
  data to resolve against.
  """

  require Logger

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.StrategyVersion

  @doc """
  Activates `version`: for each of its target pool's members, resolves a
  contract per `option_leg_config` and starts a `ContractMonitor` (a
  no-op if one is already running for that `{sim_run_id, contract_key}`
  — mirrors `StrategyActivator`'s own `whereis/2`-before-start guard).

  Returns `{:ok, [pid]}` for the monitors started/already running, or
  `{:error, reason}` if the version has no target pool or an
  unsupported `option_leg_config`.
  """
  @spec activate(StrategyVersion.t()) ::
          {:ok, [pid()]} | {:error, :no_target_pool} | {:error, :unsupported_leg_config}
  def activate(%StrategyVersion{target_pool_id: nil}), do: {:error, :no_target_pool}

  def activate(%StrategyVersion{} = version) do
    with {:ok, contract_template} <- resolve_contract_template(version.option_leg_config) do
      pool = Sim.get_target_pool!(version.target_pool_id)

      pids =
        pool.target_pool_members
        |> Enum.map(&start_for_member(version, &1, contract_template))
        |> Enum.reject(&is_nil/1)

      {:ok, pids}
    end
  end

  defp resolve_contract_template(%{
         "expiry_selection" => expiry_selection,
         "fixed_expiry" => expiry,
         "strike_selection" => "fixed_strike",
         "fixed_strike" => strike,
         "right" => right
       })
       when expiry_selection in ["fixed", "leaps"] and right in ["C", "P"] do
    {:ok, %{expiry: expiry, strike: Decimal.new(to_string(strike)), right: right}}
  end

  defp resolve_contract_template(_config), do: {:error, :unsupported_leg_config}

  defp start_for_member(version, member, contract_template) do
    contract_key =
      {member.symbol, contract_template.expiry, contract_template.strike, contract_template.right}

    open_runs = Sim.list_open_sim_runs(version)

    existing_run =
      Enum.find(open_runs, fn run ->
        {run.symbol, run.expiry, run.strike, run.right} == contract_key
      end)

    case existing_run do
      %{id: run_id} ->
        start_or_find_monitor(version, run_id, contract_key, member.exchange)

      nil ->
        start_new_run_and_monitor(version, member, contract_key)
    end
  end

  defp start_new_run_and_monitor(version, member, {symbol, expiry, strike, right}) do
    case Sim.open_sim_run(version, %{
           symbol: symbol,
           expiry: expiry,
           strike: strike,
           right: right,
           multiplier: 100,
           direction: version.direction
         }) do
      {:ok, run} ->
        start_or_find_monitor(version, run.id, {symbol, expiry, strike, right}, member.exchange)

      {:error, reason} ->
        Logger.error(
          "SimActivator: failed to open sim_run for #{version.id}/#{member.symbol}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp start_or_find_monitor(version, run_id, contract_key, exchange) do
    case ContractMonitor.whereis(run_id, contract_key) do
      nil ->
        spec = %{
          id: {run_id, contract_key},
          start:
            {ContractMonitor, :start_link,
             [
               [
                 exchange: exchange,
                 sim_run_id: run_id,
                 contract_key: contract_key,
                 strategy_version: version,
                 direction: version.direction,
                 quantity: 1
               ]
             ]},
          restart: :transient
        }

        case DynamicSupervisor.start_child(TradingOptionsSim.MonitorSupervisor, spec) do
          {:ok, pid} ->
            pid

          {:error, reason} ->
            Logger.error(
              "SimActivator: failed to start monitor for #{version.id}/#{inspect(contract_key)}: #{inspect(reason)}"
            )

            nil
        end

      pid ->
        pid
    end
  end
end
