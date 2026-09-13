defmodule TradingOptionsSimWeb.Api.StrategyController do
  use TradingOptionsSimWeb, :controller

  alias TradingOptionsSim.Sim
  alias TradingOptionsSimWeb.Api.Serializer

  action_fallback TradingOptionsSimWeb.Api.FallbackController

  plug TradingOptionsSimWeb.ApiAuthPlug,
       [scope: "strategies:read"] when action in [:index, :show]

  plug TradingOptionsSimWeb.ApiAuthPlug,
       [scope: "strategies:write"] when action in [:create, :create_version]

  def index(conn, _params) do
    strategies = Sim.list_strategies() |> Enum.map(&Serializer.strategy/1)
    json(conn, %{"strategies" => strategies})
  end

  def show(conn, %{"id" => id}) do
    strategy = Sim.get_strategy!(id)
    json(conn, %{"strategy" => Serializer.strategy(strategy)})
  end

  def create(conn, params) do
    with {:ok, strategy} <- Sim.create_strategy(params) do
      conn
      |> put_status(:created)
      |> json(%{"strategy" => Serializer.strategy(strategy)})
    end
  end

  def create_version(conn, %{"id" => strategy_id} = params) do
    strategy = Sim.get_strategy!(strategy_id)

    with {:ok, version} <- Sim.create_strategy_version(strategy, params) do
      conn
      |> put_status(:created)
      |> json(%{"strategy_version" => Serializer.strategy_version(version)})
    end
  end
end
