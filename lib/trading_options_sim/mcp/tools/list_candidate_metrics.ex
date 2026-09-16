defmodule TradingOptionsSim.MCP.Tools.ListCandidateMetrics do
  @moduledoc """
  The same `Sim.full_universe_version_metrics/0` + `CandidateGates` data
  `/candidates` renders — one row per non-deleted `discovery`/
  `quarantine` version, each paired with its nine gate verdicts.
  Computed fresh on every call (not a cached/rolled-up read), same as
  the LiveView. Mirrors `GET /api/v1/versions/metrics`; both use
  `TradingOptionsSimWeb.Api.Serializer.candidate_metrics/1` so field
  names never drift between the two surfaces. Read-only, requires
  `"strategies:read"` scope (matching that REST endpoint's own scope).
  """

  use Anubis.Server.Component, type: :tool, scopes: ["strategies:read"]

  alias Anubis.Server.Response
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim
  alias TradingOptionsSimWeb.Api.Serializer

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case CallGuard.run(&list/0) do
      {:error, :timeout} ->
        {:error, Anubis.MCP.Error.execution("timed out listing candidate metrics"), frame}

      body ->
        {:reply, Response.json(Response.tool(), body), frame}
    end
  end

  defp list do
    %{
      candidate_metrics:
        Sim.full_universe_version_metrics() |> Enum.map(&Serializer.candidate_metrics/1)
    }
  end
end
