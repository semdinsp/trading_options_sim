defmodule TradingOptionsSim.MCP.Tools.DowngradeVersion do
  @moduledoc """
  Downgrades a `StrategyVersion` — `TradingOptionsSim.Sim.downgrade_strategy_version/3`.
  `to` is `"retired"` (from any non-terminal stage) or `"quarantine"`
  (from `"test_portfolio"` only). Requires `"mcp:write"` scope.
  Rate-limited per token.
  """

  use Anubis.Server.Component, type: :tool, scopes: ["mcp:write"]

  alias Anubis.MCP.Error
  alias Anubis.Server.{Frame, Response}
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.StrategyVersion

  schema do
    field :version_id, :string, required: true, description: "StrategyVersion UUID"
    field :to, :string, required: true, description: "Target stage: retired | quarantine"

    field :reason, :string,
      required: false,
      description: "Retired reason (manual | failed_quarantine | abandoned), default manual"
  end

  @impl true
  def execute(params, frame) do
    identity = Frame.subject(frame) || "anonymous"

    if CallGuard.rate_limited?(identity, "downgrade_version") do
      {:error, Error.execution("rate limit exceeded for downgrade_version"), frame}
    else
      version_id = params.version_id
      to = params.to
      reason = Map.get(params, :reason, "manual")

      case CallGuard.run(fn -> downgrade(version_id, to, reason) end) do
        {:error, :timeout} ->
          {:error, Error.execution("timed out downgrading version #{version_id}"), frame}

        {:error, :not_found} ->
          {:error, Error.execution("no strategy version with id #{version_id}"), frame}

        {:error, :invalid_transition} ->
          {:error,
           Error.execution("invalid transition to #{to} from this version's current stage"),
           frame}

        {:error, %{errors: errors}} ->
          {:error, Error.execution("failed to downgrade version: #{inspect(errors)}"), frame}

        body ->
          {:reply, Response.json(Response.tool(), body), frame}
      end
    end
  end

  defp downgrade(id, to, reason) do
    reason = if reason in StrategyVersion.retired_reasons(), do: reason, else: "manual"
    version = Sim.get_strategy_version!(id)

    case Sim.downgrade_strategy_version(version, to, reason) do
      {:ok, version} -> %{id: version.id, lifecycle_stage: version.lifecycle_stage}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end
end
