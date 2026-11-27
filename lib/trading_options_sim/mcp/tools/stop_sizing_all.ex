defmodule TradingOptionsSim.MCP.Tools.StopSizingAll do
  @moduledoc """
  One stop-sizing summary row per version with stop ladder rows
  (`Sim.StopSizing.stop_sizing_all/1`). Read-only, requires
  `"strategies:read"`.
  """

  use Anubis.Server.Component, type: :tool, scopes: ["strategies:read"]

  alias Anubis.Server.Response
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.MCP.Tools.StopSizing, as: StopSizingTool
  alias TradingOptionsSim.Sim.StopSizing

  @impl true
  def description do
    """
    One summary row per version that has stop ladder rows (see stop_sizing): n_runs, n_sessions, the real controls' lcb90_session, the best rung by lcb90_session, and the suggested rung or the reason there is none. In-sample. Optionally one stage.
    """
  end

  schema do
    field :stage, :string,
      required: false,
      description: "discovery | quarantine | test_portfolio | retired (omit for all)"

    field :with_tp, :boolean,
      required: false,
      description: "Rungs with the take-profit (default true)"

    field :since, :string, required: false, description: "Runs entered on or after (YYYY-MM-DD)"

    field :min_sessions, :integer,
      required: false,
      description: "Sessions before a rung can be suggested (default 10)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, since} <- StopSizingTool.parse_date(params[:since]) do
      opts = [
        stage: params[:stage],
        with_tp: Map.get(params, :with_tp, true),
        since: since,
        min_sessions: Map.get(params, :min_sessions, 10)
      ]

      case CallGuard.run(fn -> StopSizing.stop_sizing_all(opts) end) do
        {:error, :timeout} ->
          {:error, Anubis.MCP.Error.execution("timed out computing stop sizing"), frame}

        {:error, :invalid_stage} ->
          {:error,
           Anubis.MCP.Error.execution(
             "stage must be one of discovery, quarantine, test_portfolio, retired"
           ), frame}

        {:ok, rows} ->
          {:reply, Response.json(Response.tool(), %{stop_sizing_all: rows}), frame}
      end
    else
      :error -> {:error, Anubis.MCP.Error.execution("since must be a date, YYYY-MM-DD"), frame}
    end
  end
end
