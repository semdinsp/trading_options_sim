defmodule TradingOptionsSim.MCP.Tools.ActivateVersion do
  @moduledoc """
  Activates a `StrategyVersion` — `TradingOptionsSim.SimActivator.activate/1`.
  Starts (or finds already-running) `ContractMonitor`s for every member
  of the version's own target pool. Requires `"mcp:write"` scope.
  Rate-limited per token.
  """

  use Anubis.Server.Component, type: :tool, scopes: ["mcp:write"]

  alias Anubis.MCP.Error
  alias Anubis.Server.{Frame, Response}
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.SimActivator

  schema do
    field :version_id, :string, required: true, description: "StrategyVersion UUID"
  end

  @impl true
  def execute(%{version_id: id}, frame) do
    identity = Frame.subject(frame) || "anonymous"

    if CallGuard.rate_limited?(identity, "activate_version") do
      {:error, Error.execution("rate limit exceeded for activate_version"), frame}
    else
      case CallGuard.run(fn -> activate(id) end) do
        {:error, :timeout} ->
          {:error, Error.execution("timed out activating version #{id}"), frame}

        {:error, :not_found} ->
          {:error, Error.execution("no strategy version with id #{id}"), frame}

        {:error, :no_target_pool} ->
          {:error, Error.execution("cannot activate — this version has no target_pool_id set"),
           frame}

        {:error, :unsupported_leg_config} ->
          {:error,
           Error.execution(
             "cannot activate — option_leg_config isn't a supported fixed_strike/fixed selection"
           ), frame}

        body ->
          {:reply, Response.json(Response.tool(), body), frame}
      end
    end
  end

  defp activate(id) do
    version = Sim.get_strategy_version!(id)

    case SimActivator.activate(version) do
      {:ok, pids, unsubscribed_symbols} ->
        %{
          id: version.id,
          monitors_running: length(pids),
          unsubscribed_symbols: unsubscribed_symbols
        }

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end
end
