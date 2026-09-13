defmodule TradingOptionsSim.MCP.Tools.GetTargetPool do
  @moduledoc "One `TargetPool` with its members. Read-only, no scope required."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim

  schema do
    field :target_pool_id, :string, required: true, description: "TargetPool UUID"
  end

  @impl true
  def execute(%{target_pool_id: id}, frame) do
    case CallGuard.run(fn -> fetch(id) end) do
      {:error, :timeout} ->
        {:error, Anubis.MCP.Error.execution("timed out fetching target pool #{id}"), frame}

      {:error, :not_found} ->
        {:error, Anubis.MCP.Error.execution("no target pool with id #{id}"), frame}

      body ->
        {:reply, Response.json(Response.tool(), body), frame}
    end
  end

  defp fetch(id) do
    pool = Sim.get_target_pool!(id)

    %{
      target_pool: %{id: pool.id, name: pool.name, region: pool.region, inverse: pool.inverse},
      members:
        Enum.map(pool.target_pool_members, fn m ->
          %{id: m.id, symbol: m.symbol, exchange: m.exchange, currency: m.currency}
        end)
    }
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end
end
