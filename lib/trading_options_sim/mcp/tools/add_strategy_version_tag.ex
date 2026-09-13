defmodule TradingOptionsSim.MCP.Tools.AddStrategyVersionTag do
  @moduledoc """
  Get-or-creates a `Tag` by exact name and unions it onto a version's
  existing tags — `TradingOptionsSim.Sim.add_tag_to_strategy_version_by_name/2`.
  Applying an already-present tag is a no-op success, not an error.
  Requires `"mcp:write"` scope. Rate-limited per token.
  """

  use Anubis.Server.Component, type: :tool, scopes: ["mcp:write"]

  alias Anubis.MCP.Error
  alias Anubis.Server.{Frame, Response}
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim

  schema do
    field :version_id, :string, required: true, description: "StrategyVersion UUID"
    field :name, :string, required: true, description: "Tag name (exact match, get-or-created)"
  end

  @impl true
  def execute(%{version_id: id, name: name}, frame) do
    identity = Frame.subject(frame) || "anonymous"

    if CallGuard.rate_limited?(identity, "add_strategy_version_tag") do
      {:error, Error.execution("rate limit exceeded for add_strategy_version_tag"), frame}
    else
      case CallGuard.run(fn -> add_tag(id, name) end) do
        {:error, :timeout} ->
          {:error, Error.execution("timed out tagging version #{id}"), frame}

        {:error, :not_found} ->
          {:error, Error.execution("no strategy version with id #{id}"), frame}

        body ->
          {:reply, Response.json(Response.tool(), body), frame}
      end
    end
  end

  defp add_tag(id, name) do
    version = Sim.get_strategy_version!(id)

    case Sim.add_tag_to_strategy_version_by_name(version, name) do
      {:ok, version} -> %{id: version.id, tags: Enum.map(version.tags, & &1.name)}
      {:error, changeset} -> %{error: inspect(changeset.errors)}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end
end
