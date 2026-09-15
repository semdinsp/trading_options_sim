defmodule TradingOptionsSim.MCP.Tools.ListSimRuns do
  @moduledoc """
  Lists `SimRun`s across every strategy version, optionally filtered to
  one `status` and paginated — backed by
  `TradingOptionsSim.Sim.list_sim_runs_page/2`. Read-only, requires
  `"runs:read"` scope (matching the REST `GET /api/v1/runs` endpoint's
  own scope requirement).
  """

  use Anubis.Server.Component, type: :tool, scopes: ["runs:read"]

  alias Anubis.Server.Response
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim

  @default_limit 20

  schema do
    field :status, :string,
      required: false,
      description: "Filter to \"open\" or \"closed\" (omit for every run)"

    field :limit, :integer,
      required: false,
      description: "Max runs to return (default #{@default_limit}, clamped to 100)"

    field :offset, :integer,
      required: false,
      description: "How many runs to skip before this page starts (default 0)"
  end

  @impl true
  def execute(params, frame) do
    status = Map.get(params, :status)
    limit = Map.get(params, :limit, @default_limit)
    offset = Map.get(params, :offset, 0)

    case CallGuard.run(fn -> list(status, limit, offset) end) do
      {:error, :timeout} ->
        {:error, Anubis.MCP.Error.execution("timed out listing sim runs"), frame}

      body ->
        {:reply, Response.json(Response.tool(), body), frame}
    end
  end

  defp list(status, limit, offset) do
    {runs, total_count} = Sim.list_sim_runs_page(status, limit: limit, offset: offset)

    %{
      runs: Enum.map(runs, &summarize/1),
      total_count: total_count,
      limit: limit,
      offset: offset
    }
  end

  defp summarize(run) do
    %{
      id: run.id,
      strategy_version_id: run.strategy_version_id,
      strategy_name: run.strategy_version.strategy.name,
      version: run.strategy_version.version,
      symbol: run.symbol,
      expiry: run.expiry,
      strike: str(run.strike),
      right: run.right,
      direction: run.direction,
      status: run.status,
      entry_at: run.entry_at,
      entry_price: str(run.entry_price),
      exit_at: run.exit_at,
      exit_price: str(run.exit_price),
      exit_reason: run.exit_reason,
      realized_pnl: str(run.realized_pnl),
      realized_pnl_net: str(run.realized_pnl_net),
      tags: Enum.map(run.tags, & &1.name)
    }
  end

  # Jason has no built-in Decimal encoder — same reason
  # TradingOptionsSimWeb.Api.Serializer's own `str/1` exists.
  defp str(nil), do: nil
  defp str(%Decimal{} = d), do: Decimal.to_string(d)
  defp str(other), do: other
end
