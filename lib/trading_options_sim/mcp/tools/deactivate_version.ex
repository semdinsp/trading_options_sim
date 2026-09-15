defmodule TradingOptionsSim.MCP.Tools.DeactivateVersion do
  @moduledoc """
  Deactivates a `StrategyVersion` — `TradingOptionsSim.SimActivator.deactivate/1`.
  Flattens any open position and stops every running `ContractMonitor`
  for the version (including a flat-but-alive one with no open
  `SimRun`). Requires `"mcp:write"` scope. Rate-limited per token.
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

    if CallGuard.rate_limited?(identity, "deactivate_version") do
      {:error, Error.execution("rate limit exceeded for deactivate_version"), frame}
    else
      case CallGuard.run(fn -> deactivate(id) end) do
        {:error, :timeout} ->
          {:error, Error.execution("timed out deactivating version #{id}"), frame}

        {:error, :not_found} ->
          {:error, Error.execution("no strategy version with id #{id}"), frame}

        body ->
          {:reply, Response.json(Response.tool(), body), frame}
      end
    end
  end

  defp deactivate(id) do
    version = Sim.get_strategy_version!(id)
    {:ok, count} = SimActivator.deactivate(version)
    %{id: version.id, monitors_stopped: count}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end
end
