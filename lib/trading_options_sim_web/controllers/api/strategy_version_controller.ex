defmodule TradingOptionsSimWeb.Api.StrategyVersionController do
  use TradingOptionsSimWeb, :controller

  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.SimActivator
  alias TradingOptionsSimWeb.Api.Serializer

  action_fallback TradingOptionsSimWeb.Api.FallbackController

  plug TradingOptionsSimWeb.ApiAuthPlug,
       [scope: "strategies:read"] when action in [:index, :show, :metrics, :promotion_export]

  plug TradingOptionsSimWeb.ApiAuthPlug,
       [scope: "strategies:write"]
       when action in [
              :promote,
              :downgrade,
              :activate,
              :deactivate,
              :link_live_strategy,
              :unlink_live_strategy,
              :update_trading_hours,
              :update_notes
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

  @doc """
  GET /api/v1/versions/:id/promotion_export

  The single payload trading_live promotes from -- see
  `TradingOptionsSim.Sim.PromotionExport` for the contract. 404 for an
  unknown id.
  """
  def promotion_export(conn, %{"id" => id}) do
    case TradingOptionsSim.Sim.PromotionExport.build(id) do
      {:ok, payload} -> json(conn, payload)
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{"error" => "not_found"})
    end
  end

  @doc """
  GET /api/v1/versions/metrics

  The same `Sim.full_universe_version_metrics/0` + `CandidateGates`
  data `/candidates` renders — one row per non-deleted
  `discovery`/`quarantine` version, each paired with its nine gate
  verdicts. Computed fresh on every call, same as the LiveView (not a
  cached/rolled-up read) — see `full_universe_version_metrics/0`'s own
  doc for why. Mirrors the `list_candidate_metrics` MCP tool; both use
  `Serializer.candidate_metrics/1` so field names never drift between
  the two surfaces.
  """
  def metrics(conn, _params) do
    rows = Sim.full_universe_version_metrics() |> Enum.map(&Serializer.candidate_metrics/1)
    json(conn, %{"candidate_metrics" => rows})
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

  @doc """
  POST /api/v1/versions/:id/trading_hours {"trading_hours_policy": "unrestricted", "overnight_hold": true}

  Either key may be omitted — see `StrategyVersion.operational_changeset/2`'s
  own doc for why this is a separate, deliberate-exception changeset
  from a version's immutable trading logic.
  """
  def update_trading_hours(conn, %{"id" => id} = params) do
    version = Sim.get_strategy_version!(id)
    attrs = Map.take(params, ["trading_hours_policy", "overnight_hold"])

    with {:ok, version} <- Sim.update_trading_hours_settings(version, attrs) do
      json(conn, %{"strategy_version" => Serializer.strategy_version(version)})
    end
  end

  @doc """
  PATCH /api/v1/versions/:id/notes {"notes": "..."}

  Same "deliberate exception, revisable commentary" changeset
  `StrategyVersionDetailLive`'s own notes editor already uses
  (`Sim.set_strategy_version_notes/2`/`StrategyVersion.notes_changeset/2`)
  — this was a real gap before this endpoint existed: notes could be
  set from the UI but not from REST or MCP at all.
  """
  def update_notes(conn, %{"id" => id, "notes" => notes}) do
    version = Sim.get_strategy_version!(id)

    with {:ok, version} <- Sim.set_strategy_version_notes(version, notes) do
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
