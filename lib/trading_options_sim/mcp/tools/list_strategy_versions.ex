defmodule TradingOptionsSim.MCP.Tools.ListStrategyVersions do
  @moduledoc """
  Lists `StrategyVersion`s across every strategy, full detail
  (rules/notes/tags/activation status included — unlike
  `ListStrategies`'/`GetStrategy`'s own deliberately-thin per-version
  summaries), optionally filtered to one `lifecycle_stage` and paginated
  — backed by `TradingOptionsSim.Sim.list_strategy_versions_page/2`.
  Read-only, no scope required.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim

  @default_limit 20

  schema do
    field :stage, :string,
      required: false,
      description:
        "Filter to one lifecycle_stage: discovery | quarantine | test_portfolio | retired (omit for every stage)"

    field :limit, :integer,
      required: false,
      description: "Max versions to return (default #{@default_limit}, clamped to 100)"

    field :offset, :integer,
      required: false,
      description: "How many versions to skip before this page starts (default 0)"
  end

  @impl true
  def execute(params, frame) do
    stage = Map.get(params, :stage)
    limit = Map.get(params, :limit, @default_limit)
    offset = Map.get(params, :offset, 0)

    case CallGuard.run(fn -> list(stage, limit, offset) end) do
      {:error, :timeout} ->
        {:error, Anubis.MCP.Error.execution("timed out listing strategy versions"), frame}

      body ->
        {:reply, Response.json(Response.tool(), body), frame}
    end
  end

  defp list(stage, limit, offset) do
    {versions, total_count} =
      Sim.list_strategy_versions_page(stage, limit: limit, offset: offset)

    %{
      versions: Enum.map(versions, &summarize/1),
      total_count: total_count,
      limit: limit,
      offset: offset
    }
  end

  defp summarize(version) do
    %{
      id: version.id,
      strategy_id: version.strategy_id,
      strategy_name: version.strategy.name,
      version: version.version,
      lifecycle_stage: version.lifecycle_stage,
      direction: version.direction,
      rules: version.rules,
      position_sizing: version.position_sizing,
      option_leg_config: version.option_leg_config,
      target_pool_id: version.target_pool_id,
      activated_at: version.activated_at,
      deactivated_at: version.deactivated_at,
      trading_hours_policy: version.trading_hours_policy,
      overnight_hold: version.overnight_hold,
      notes: version.notes,
      rating: version.rating,
      tags: Enum.map(version.tags, & &1.name)
    }
  end
end
