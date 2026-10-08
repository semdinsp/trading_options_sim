defmodule TradingOptionsSim.MCP.Tools.ExpectancyByRegime do
  @moduledoc """
  Expectancy in R per regime at entry (`context.regime_label`, e.g.
  "calm|up"), for one strategy version or for every non-deleted version
  with a closed run, optionally filtered by `stage`. Backed by
  `Sim.expectancy_by_regime/1` and mirrors trading_system's
  `get_expectancy_by_regime`. Mirrors `GET /api/v1/versions/:id/expectancy_by_regime`
  and `GET /api/v1/versions/expectancy_by_regime`; both use
  `TradingOptionsSimWeb.Api.Serializer.expectancy_by_regime/1`.
  Read-only, requires `"strategies:read"` (as `list_candidate_metrics`).
  """

  use Anubis.Server.Component, type: :tool, scopes: ["strategies:read"]

  alias Anubis.Server.Response
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim
  alias TradingOptionsSimWeb.Api.Serializer

  @impl true
  def description do
    """
    Expectancy in R bucketed by the market regime at entry (regime_label such as "calm|up"; runs without one are in "uncategorized").

    Same R, cost basis and population as list_candidate_metrics: R = net P&L / premium at risk, net of measured commissions; churned and excluded runs are left out of each bucket's top-level stats. Each bucket's `all_trades` has the same stats including them. A version's buckets sum to its list_candidate_metrics scored_runs / scored_total_r, and `total` equals them.

    Per bucket: n (never null), n_sessions (distinct UTC exit dates), total_r, expectancy_r, sd_r, lcb90, realized_pnl_net, win_rate. expectancy_r, sd_r and lcb90 are null when n < 2.

    lcb90 is a ONE-SIDED 90% lower bound (z = 1.2816). It is NOT comparable with list_candidate_metrics' lcb95 (one-sided 95%).

    For observation only, not for automated selection or sizing: most buckets have small n for now.

    Pass version_id for one version; omit it for every version with a closed run (optionally filtered by stage).
    """
  end

  schema do
    field :version_id, :string,
      required: false,
      description: "StrategyVersion UUID. Omit to return every version with a closed run."

    field :stage, :string,
      required: false,
      description:
        "Only when version_id is omitted: discovery | quarantine | test_portfolio | retired"
  end

  @impl true
  def execute(params, frame) do
    opts = [version_id: Map.get(params, :version_id), stage: Map.get(params, :stage)]

    case CallGuard.run(fn -> Sim.expectancy_by_regime(opts) end) do
      {:error, :timeout} ->
        {:error, Anubis.MCP.Error.execution("timed out computing expectancy by regime"), frame}

      {:error, :not_found} ->
        {:error, Anubis.MCP.Error.execution("no strategy version with id #{params[:version_id]}"),
         frame}

      {:error, :invalid_stage} ->
        {:error,
         Anubis.MCP.Error.execution(
           "stage must be one of discovery, quarantine, test_portfolio, retired"
         ), frame}

      {:ok, rows} ->
        body = %{expectancy_by_regime: Enum.map(rows, &Serializer.expectancy_by_regime/1)}
        {:reply, Response.json(Response.tool(), body), frame}
    end
  end
end
