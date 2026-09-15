defmodule TradingOptionsSimWeb.Api.RunController do
  use TradingOptionsSimWeb, :controller

  alias TradingOptionsSim.Sim
  alias TradingOptionsSimWeb.Api.Serializer

  action_fallback TradingOptionsSimWeb.Api.FallbackController

  plug TradingOptionsSimWeb.ApiAuthPlug, [scope: "runs:read"] when action in [:index, :show]

  @doc """
  GET /api/v1/runs?status=open&limit=20&offset=0

  `status` (optional) filters to `"open"` or `"closed"` — omit for
  every run, matching `RunsLive`'s own "All" filter and
  `Sim.list_sim_runs/1`'s `nil` default. `limit`/`offset` paginate (see
  `Sim.list_sim_runs_page/2`'s own doc); response includes
  `"total_count"` so a caller can tell whether more pages remain
  without a second round trip.
  """
  def index(conn, params) do
    opts = Serializer.pagination_opts(params)
    {runs, total_count} = Sim.list_sim_runs_page(params["status"], opts)

    json(conn, %{
      "sim_runs" => Enum.map(runs, &Serializer.sim_run/1),
      "total_count" => total_count,
      "limit" => Keyword.fetch!(opts, :limit),
      "offset" => Keyword.fetch!(opts, :offset)
    })
  end

  def show(conn, %{"id" => id}) do
    run = Sim.get_sim_run!(id)
    json(conn, %{"sim_run" => Serializer.sim_run(run)})
  end
end
