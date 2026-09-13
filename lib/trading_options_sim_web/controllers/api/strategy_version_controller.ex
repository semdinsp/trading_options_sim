defmodule TradingOptionsSimWeb.Api.StrategyVersionController do
  use TradingOptionsSimWeb, :controller

  alias TradingOptionsSim.Sim
  alias TradingOptionsSimWeb.Api.Serializer

  action_fallback TradingOptionsSimWeb.Api.FallbackController

  plug TradingOptionsSimWeb.ApiAuthPlug, [scope: "strategies:read"] when action in [:show]

  plug TradingOptionsSimWeb.ApiAuthPlug,
       [scope: "strategies:write"]
       when action in [:promote, :downgrade, :promote_to_live_app]

  plug TradingOptionsSimWeb.ApiAuthPlug,
       [scope: "tags:write"] when action in [:put_tags, :add_tag]

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

  @doc "POST /api/v1/versions/:id/promote_to_live_app {\"live_app\": \"trading_live\", \"live_strategy_id\": \"...\"}"
  def promote_to_live_app(conn, %{
        "id" => id,
        "live_app" => live_app,
        "live_strategy_id" => live_strategy_id
      }) do
    version = Sim.get_strategy_version!(id)

    with {:ok, version} <- Sim.promote_to_live_app(version, live_app, live_strategy_id) do
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
end
