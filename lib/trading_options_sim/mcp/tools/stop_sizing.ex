defmodule TradingOptionsSim.MCP.Tools.StopSizing do
  @moduledoc """
  Stop sizing for one strategy version from its stop ladder
  (`Sim.StopSizing.stop_sizing/2`). Read-only, requires
  `"strategies:read"`.
  """

  use Anubis.Server.Component, type: :tool, scopes: ["strategies:read"]

  alias Anubis.Server.Response
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim.StopSizing

  @impl true
  def description do
    """
    What each virtual stop on the stop ladder would have returned on this version's own trades, against its real risk controls over the same trades and sessions.

    Every run since the ladder started carries virtual stops evaluated on the same quotes as the run: premium stops at 5/7.5/10/15/20/25/35/50% below entry on the mid and "premium:none"; underlying stops at 0.5/1/1.5/2 x the 20-minute ATR (daily ATR x sqrt(20/390)); a 15-minute "not working" time stop. Each with the version's take-profit (with_tp true) and without it (false). Rungs keep the version's rule exit and EOD flatten and keep recording after the real run's stop or target fires.

    R = net P&L / premium at risk. A session is the New York entry date; its R is the sum of its runs' R. lcb90_session is a one-sided 90% lower bound (z = 1.2816) on mean session R. delta_vs_actual_lcb90 is the same bound on the per-session difference against the real controls.

    Returns: actual (the real controls), ladder (per rung: n, n_sessions, stop_fire_rate, sum_r, mean_r, win_rate, worst_r, p05_r, lcb90_session, delta_vs_actual_mean/lcb90), excursion_profile (MAE percentiles of eventual winners and losers, and the share of winners each rung cut), stop_value and tp_value (realised R minus the no-stop/no-target shadow R over real stop and target exits; mean stop slippage), suggestion (a rung only if n_sessions >= min_sessions, its lcb90_session beats the real controls', the paired lcb90 > 0 and mean R > 0; else rung null with the reason) and caveats (regime mix, pre-ladder and incomplete-ladder runs).

    Everything is in-sample (in_sample: true). For observation, not for automated sizing.
    """
  end

  schema do
    field :version_id, :string, required: true, description: "StrategyVersion UUID"

    field :with_tp, :boolean,
      required: false,
      description: "Rungs with the version's take-profit (default true) or without it (false)"

    field :since, :string,
      required: false,
      description: "Only runs entered on or after this date (YYYY-MM-DD)"

    field :min_sessions, :integer,
      required: false,
      description: "Sessions a rung needs before it can be suggested (default 10)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, since} <- parse_date(params[:since]) do
      opts = [
        with_tp: Map.get(params, :with_tp, true),
        since: since,
        min_sessions: Map.get(params, :min_sessions, 10)
      ]

      case CallGuard.run(fn -> StopSizing.stop_sizing(params[:version_id], opts) end) do
        {:error, :timeout} ->
          {:error, Anubis.MCP.Error.execution("timed out computing stop sizing"), frame}

        {:error, :not_found} ->
          {:error,
           Anubis.MCP.Error.execution("no strategy version with id #{params[:version_id]}"),
           frame}

        {:ok, report} ->
          {:reply, Response.json(Response.tool(), %{stop_sizing: report}), frame}
      end
    else
      :error -> {:error, Anubis.MCP.Error.execution("since must be a date, YYYY-MM-DD"), frame}
    end
  end

  @doc false
  def parse_date(nil), do: {:ok, nil}

  def parse_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, d} -> {:ok, d}
      _ -> :error
    end
  end
end
