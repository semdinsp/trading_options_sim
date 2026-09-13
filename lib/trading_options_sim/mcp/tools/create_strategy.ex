defmodule TradingOptionsSim.MCP.Tools.CreateStrategy do
  @moduledoc """
  Creates a new `Strategy` — `TradingOptionsSim.Sim.create_strategy/1`.
  Requires `"mcp:write"` scope. Rate-limited per token via
  `CallGuard.rate_limited?/2`.
  """

  use Anubis.Server.Component, type: :tool, scopes: ["mcp:write"]

  alias Anubis.MCP.Error
  alias Anubis.Server.{Frame, Response}
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim

  schema do
    field :name, :string, required: true, description: "Strategy name"
    field :notes, :string, required: false, description: "Optional notes"
  end

  @impl true
  def execute(params, frame) do
    identity = Frame.subject(frame) || "anonymous"

    if CallGuard.rate_limited?(identity, "create_strategy") do
      {:error, Error.execution("rate limit exceeded for create_strategy"), frame}
    else
      case CallGuard.run(fn -> Sim.create_strategy(params) end) do
        {:error, :timeout} ->
          {:error, Error.execution("timed out creating strategy"), frame}

        {:ok, strategy} ->
          {:reply, Response.json(Response.tool(), %{id: strategy.id, name: strategy.name}), frame}

        {:error, changeset} ->
          {:error, Error.execution("failed to create strategy: #{inspect(changeset.errors)}"),
           frame}
      end
    end
  end
end
