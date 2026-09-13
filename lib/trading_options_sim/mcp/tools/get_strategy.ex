defmodule TradingOptionsSim.MCP.Tools.GetStrategy do
  @moduledoc "One `Strategy` plus every non-deleted version, full detail. Read-only, no scope required."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim

  schema do
    field :strategy_id, :string, required: true, description: "Strategy UUID"
  end

  @impl true
  def execute(%{strategy_id: id}, frame) do
    case CallGuard.run(fn -> fetch(id) end) do
      {:error, :timeout} ->
        {:error, Anubis.MCP.Error.execution("timed out fetching strategy #{id}"), frame}

      {:error, :not_found} ->
        {:error, Anubis.MCP.Error.execution("no strategy with id #{id}"), frame}

      body ->
        {:reply, Response.json(Response.tool(), body), frame}
    end
  end

  defp fetch(id) do
    strategy = Sim.get_strategy!(id)
    versions = Sim.list_strategy_versions_for_strategy(strategy)

    %{
      strategy: %{
        id: strategy.id,
        name: strategy.name,
        notes: strategy.notes,
        asset_class: strategy.asset_class
      },
      versions:
        Enum.map(versions, fn v ->
          %{
            id: v.id,
            version: v.version,
            lifecycle_stage: v.lifecycle_stage,
            direction: v.direction,
            rating: v.rating
          }
        end)
    }
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end
end
