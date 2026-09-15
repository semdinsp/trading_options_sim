defmodule TradingOptionsSim.MCP.Tools.UpdateStrategyVersionNotes do
  @moduledoc """
  Sets a `StrategyVersion`'s `notes` — the same deliberate-exception,
  revisable-commentary changeset (`Sim.set_strategy_version_notes/2`/
  `StrategyVersion.notes_changeset/2`) `StrategyVersionDetailLive`'s own
  notes editor already uses. Closes a real gap: before this tool
  existed, notes could be set from the UI but not from REST or MCP at
  all.

  Requires `"mcp:write"` scope. Rate-limited per token.
  """

  use Anubis.Server.Component, type: :tool, scopes: ["mcp:write"]

  alias Anubis.MCP.Error
  alias Anubis.Server.{Frame, Response}
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim

  schema do
    field :version_id, :string, required: true, description: "StrategyVersion UUID"

    field :notes, :string,
      required: true,
      description: "The notes text to set (replaces any existing notes)"
  end

  @impl true
  def execute(%{version_id: id, notes: notes}, frame) do
    identity = Frame.subject(frame) || "anonymous"

    if CallGuard.rate_limited?(identity, "update_strategy_version_notes") do
      {:error, Error.execution("rate limit exceeded for update_strategy_version_notes"), frame}
    else
      case CallGuard.run(fn -> update(id, notes) end) do
        {:error, :timeout} ->
          {:error, Error.execution("timed out updating notes for version #{id}"), frame}

        {:error, :not_found} ->
          {:error, Error.execution("no strategy version with id #{id}"), frame}

        {:error, changeset} ->
          {:error, Error.execution("failed to update notes: #{inspect(changeset.errors)}"), frame}

        body ->
          {:reply, Response.json(Response.tool(), body), frame}
      end
    end
  end

  defp update(id, notes) do
    version = Sim.get_strategy_version!(id)

    case Sim.set_strategy_version_notes(version, notes) do
      {:ok, version} -> %{id: version.id, notes: version.notes}
      {:error, changeset} -> {:error, changeset}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end
end
