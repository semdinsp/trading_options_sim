defmodule TradingOptionsSim.MCP.Tools.ListStrategies do
  @moduledoc """
  Lists every `Strategy` with each version's lifecycle-stage summary,
  plus a rolled-up `tags` list (every distinct tag name across its
  versions) and `any_notes?` (whether any version has notes set) — backed
  by `TradingOptionsSim.Sim.list_strategies/0` and
  `list_strategy_versions_for_strategy/1`. Deliberately a strategy-level
  rollup, not full per-version detail — see `GetStrategy` (one strategy,
  full per-version notes/tags/activation) or `ListStrategyVersions`
  (every version, full detail, paginated) for that. Read-only, no scope
  required — see `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §4a.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias TradingOptionsSim.MCP.CallGuard
  alias TradingOptionsSim.Sim

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case CallGuard.run(fn -> Enum.map(Sim.list_strategies(), &summarize/1) end) do
      {:error, :timeout} ->
        {:error, Anubis.MCP.Error.execution("timed out listing strategies"), frame}

      strategies ->
        {:reply, Response.json(Response.tool(), %{strategies: strategies}), frame}
    end
  end

  defp summarize(strategy) do
    versions = Sim.list_strategy_versions_for_strategy(strategy)

    %{
      id: strategy.id,
      name: strategy.name,
      asset_class: strategy.asset_class,
      version_count: length(versions),
      lifecycle_stages: versions |> Enum.map(& &1.lifecycle_stage) |> Enum.uniq(),
      tags: versions |> Enum.flat_map(& &1.tags) |> Enum.map(& &1.name) |> Enum.uniq(),
      any_notes?: Enum.any?(versions, &(&1.notes not in [nil, ""]))
    }
  end
end
