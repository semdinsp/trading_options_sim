defmodule TradingOptionsSim.MCP.Tools.ListTags do
  @moduledoc "Lists every `Tag`. Read-only, no scope required."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case CallGuard.run(fn ->
           Enum.map(Sim.list_tags(), fn t -> %{id: t.id, name: t.name} end)
         end) do
      {:error, :timeout} ->
        {:error, Anubis.MCP.Error.execution("timed out listing tags"), frame}

      tags ->
        {:reply, Response.json(Response.tool(), %{tags: tags}), frame}
    end
  end
end
