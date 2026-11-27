defmodule TradingOptionsSim.MCP.Tools.StopAbReport do
  @moduledoc """
  The Stop-AB-2026-11-27 arms side by side
  (`Sim.StopSizing.stop_ab_report/1`). Read-only, requires
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
    The four Stop-AB-2026-11-27 arms (forks of 83e0: A control SL10/TP20; B SL50 no target; C underlying 1.0 x 20m ATR stop; D SL10 no target; B-D on the mid_confirmed stop trigger), side by side over the sessions every arm traded: mean session R, lcb90_session, the paired per-session difference against A and its lcb90, stop-fire rate, worst run R, quote_fill_share, and each arm's own stop ladder with and without the target. `ready` is true at >= 10 common sessions, the decision rule in each arm's notes. In-sample.
    """
  end

  schema do
    field :since, :string, required: false, description: "Runs entered on or after (YYYY-MM-DD)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, since} <- StopSizingTool.parse_date(params[:since]) do
      case CallGuard.run(fn -> StopSizing.stop_ab_report(since: since) end) do
        {:error, :timeout} ->
          {:error, Anubis.MCP.Error.execution("timed out computing the stop A/B report"), frame}

        {:ok, report} ->
          {:reply, Response.json(Response.tool(), %{stop_ab_report: report}), frame}
      end
    else
      :error -> {:error, Anubis.MCP.Error.execution("since must be a date, YYYY-MM-DD"), frame}
    end
  end
end
