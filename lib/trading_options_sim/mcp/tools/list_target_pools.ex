defmodule TradingOptionsSim.MCP.Tools.ListTargetPools do
  @moduledoc "Lists every `TargetPool`. Read-only, no scope required."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case CallGuard.run(fn ->
           Enum.map(Sim.list_target_pools(), fn p ->
             %{id: p.id, name: p.name, region: p.region, inverse: p.inverse}
           end)
         end) do
      {:error, :timeout} ->
        {:error, Anubis.MCP.Error.execution("timed out listing target pools"), frame}

      pools ->
        {:reply, Response.json(Response.tool(), %{target_pools: pools}), frame}
    end
  end
end
