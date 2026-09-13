defmodule TradingOptionsSim.MCP.Tools.PromoteVersion do
  @moduledoc """
  Promotes a `StrategyVersion` — `TradingOptionsSim.Sim.promote_strategy_version/2`.
  `to` is one of `"quarantine"`, `"test_portfolio"`, or `"discovery"`
  (the last only valid from `"retired"` — "unretire"). Requires
  `"mcp:write"` scope. Rate-limited per token.
  """

  use Anubis.Server.Component, type: :tool, scopes: ["mcp:write"]

  alias Anubis.MCP.Error
  alias Anubis.Server.{Frame, Response}
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim

  schema do
    field :version_id, :string, required: true, description: "StrategyVersion UUID"

    field :to, :string,
      required: true,
      description: "Target lifecycle stage: quarantine | test_portfolio | discovery"
  end

  @impl true
  def execute(%{version_id: id, to: to}, frame) do
    identity = Frame.subject(frame) || "anonymous"

    if CallGuard.rate_limited?(identity, "promote_version") do
      {:error, Error.execution("rate limit exceeded for promote_version"), frame}
    else
      case CallGuard.run(fn -> promote(id, to) end) do
        {:error, :timeout} ->
          {:error, Error.execution("timed out promoting version #{id}"), frame}

        {:error, :not_found} ->
          {:error, Error.execution("no strategy version with id #{id}"), frame}

        {:error, :no_target_pool} ->
          {:error,
           Error.execution(
             "cannot promote to quarantine — this version has no target_pool_id set"
           ), frame}

        {:error, :invalid_transition} ->
          {:error,
           Error.execution("invalid transition to #{to} from this version's current stage"),
           frame}

        {:error, changeset} ->
          {:error, Error.execution("failed to promote version: #{inspect(changeset.errors)}"),
           frame}

        body ->
          {:reply, Response.json(Response.tool(), body), frame}
      end
    end
  end

  defp promote(id, to) do
    version = Sim.get_strategy_version!(id)

    case Sim.promote_strategy_version(version, to) do
      {:ok, version} -> %{id: version.id, lifecycle_stage: version.lifecycle_stage}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end
end
