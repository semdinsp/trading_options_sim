defmodule TradingOptionsSimWeb.Api.StrategyVersionController do
  use TradingOptionsSimWeb, :controller

  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.SimActivator
  alias TradingOptionsSimWeb.Api.Serializer

  action_fallback TradingOptionsSimWeb.Api.FallbackController

  plug TradingOptionsSimWeb.ApiAuthPlug, [scope: "strategies:read"] when action in [:index, :show]

  plug TradingOptionsSimWeb.ApiAuthPlug,
       [scope: "strategies:write"]
       when action in [
              :promote,
              :downgrade,
              :activate,
              :deactivate,
              :link_live_strategy,
              :unlink_live_strategy
            ]

  plug TradingOptionsSimWeb.ApiAuthPlug,
       [scope: "tags:write"] when action in [:put_tags, :add_tag, :remove_tag]

  @doc """
  GET /api/v1/versions?stage=discovery&limit=20&offset=0

  `stage` (optional) filters to one `lifecycle_stage` — omit for every
  stage, matching `StrategyVersionsLive`'s own "All" filter and
  `Sim.list_strategy_versions/1`'s `nil` default. `limit`/`offset`
  paginate (`limit` clamped server-side — see
  `Sim.list_strategy_versions_page/2`'s own doc); response includes
  `"total_count"` so a caller can tell whether more pages remain
  without a second round trip.
  """
  def index(conn, params) do
    opts = Serializer.pagination_opts(params)
    {versions, total_count} = Sim.list_strategy_versions_page(params["stage"], opts)

    json(conn, %{
      "strategy_versions" => Enum.map(versions, &Serializer.strategy_version/1),
      "total_count" => total_count,
      "limit" => Keyword.fetch!(opts, :limit),
      "offset" => Keyword.fetch!(opts, :offset)
    })
  end

  def show(conn, %{"id" => id}) do
    version = Sim.get_strategy_version!(id)
    json(conn, %{"strategy_version" => Serializer.strategy_version(version)})
  end

  @doc "POST /api/v1/versions/:id/promote {\"to\": \"quarantine\" | \"test_portfolio\" | \"discovery\"}"
  def promote(conn, %{"id" => id, "to" => to}) do
    version = Sim.get_strategy_version!(id)

    with {:ok, version} <- Sim.promote_strategy_version(version, to) do
      json(conn, %{"strategy_version" => Serializer.strategy_version(version)})
    end
  end

  @doc "POST /api/v1/versions/:id/downgrade {\"to\": \"quarantine\" | \"retired\", \"reason\": \"manual\" | ...}"
  def downgrade(conn, %{"id" => id, "to" => to} = params) do
    version = Sim.get_strategy_version!(id)
    reason = Map.get(params, "reason", "manual")

    with {:ok, version} <- Sim.downgrade_strategy_version(version, to, reason) do
      json(conn, %{"strategy_version" => Serializer.strategy_version(version)})
    end
  end

  @doc "POST /api/v1/versions/:id/activate — SimActivator.activate/1. Mirrors the activate_version MCP tool/UI button."
  def activate(conn, %{"id" => id}) do
    version = Sim.get_strategy_version!(id)

    with {:ok, pids, unsubscribed_symbols} <- SimActivator.activate(version) do
      json(conn, %{
        "strategy_version" => Serializer.strategy_version(Sim.get_strategy_version!(id)),
        "monitors_running" => length(pids),
        "unsubscribed_symbols" => unsubscribed_symbols
      })
    end
  end

  @doc "POST /api/v1/versions/:id/deactivate — SimActivator.deactivate/1. Mirrors the deactivate_version MCP tool/UI button."
  def deactivate(conn, %{"id" => id}) do
    version = Sim.get_strategy_version!(id)
    {:ok, count} = SimActivator.deactivate(version)

    json(conn, %{
      "strategy_version" => Serializer.strategy_version(Sim.get_strategy_version!(id)),
      "monitors_stopped" => count
    })
  end

  @doc """
  POST /api/v1/versions/:id/link_live_strategy {"live_strategy_app": "trading_live", "live_strategy_id": "..."}

  Called by the pulling app (e.g. `trading_live`) after it has already
  built its own local record for this version — see
  `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §4. This app never calls out to the
  live-execution app; it only records the link when asked.
  """
  def link_live_strategy(conn, %{
        "id" => id,
        "live_strategy_app" => live_strategy_app,
        "live_strategy_id" => live_strategy_id
      }) do
    version = Sim.get_strategy_version!(id)

    with {:ok, version} <- Sim.link_live_strategy(version, live_strategy_app, live_strategy_id) do
      json(conn, %{"strategy_version" => Serializer.strategy_version(version)})
    end
  end

  @doc "POST /api/v1/versions/:id/unlink_live_strategy — called when the live-execution app kills/deletes/unpromotes the strategy."
  def unlink_live_strategy(conn, %{"id" => id}) do
    version = Sim.get_strategy_version!(id)

    with {:ok, version} <- Sim.unlink_live_strategy(version) do
      json(conn, %{"strategy_version" => Serializer.strategy_version(version)})
    end
  end

  @doc "POST /api/v1/versions/:id/tags {\"tag_ids\": [...]}"
  def put_tags(conn, %{"id" => id, "tag_ids" => tag_ids}) do
    version = Sim.get_strategy_version!(id)

    with {:ok, version} <- Sim.put_strategy_version_tags(version, tag_ids) do
      json(conn, %{"strategy_version" => Serializer.strategy_version(version)})
    end
  end

  @doc "POST /api/v1/versions/:id/tags/add {\"name\": \"needs review\"}"
  def add_tag(conn, %{"id" => id, "name" => name}) do
    version = Sim.get_strategy_version!(id)

    with {:ok, version} <- Sim.add_tag_to_strategy_version_by_name(version, name) do
      json(conn, %{"strategy_version" => Serializer.strategy_version(version)})
    end
  end

  @doc "DELETE /api/v1/versions/:id/tags/:tag_id — a no-op if that tag isn't currently applied."
  def remove_tag(conn, %{"id" => id, "tag_id" => tag_id}) do
    version = Sim.get_strategy_version!(id)

    with {:ok, version} <- Sim.remove_tag_from_strategy_version(version, tag_id) do
      json(conn, %{"strategy_version" => Serializer.strategy_version(version)})
    end
  end
end
