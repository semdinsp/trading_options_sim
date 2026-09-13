defmodule TradingOptionsSimWeb.Api.TargetPoolController do
  use TradingOptionsSimWeb, :controller

  alias TradingOptionsSim.Sim
  alias TradingOptionsSimWeb.Api.Serializer

  action_fallback TradingOptionsSimWeb.Api.FallbackController

  plug TradingOptionsSimWeb.ApiAuthPlug,
       [scope: "target_pools:read"] when action in [:index, :show]

  plug TradingOptionsSimWeb.ApiAuthPlug,
       [scope: "target_pools:write"] when action in [:create, :create_member]

  def index(conn, _params) do
    pools = Sim.list_target_pools() |> Enum.map(&Serializer.target_pool/1)
    json(conn, %{"target_pools" => pools})
  end

  def show(conn, %{"id" => id}) do
    pool = Sim.get_target_pool!(id)

    json(conn, %{
      "target_pool" => Serializer.target_pool(pool),
      "members" => Enum.map(pool.target_pool_members, &Serializer.target_pool_member/1)
    })
  end

  def create(conn, params) do
    with {:ok, pool} <- Sim.create_target_pool(params) do
      conn
      |> put_status(:created)
      |> json(%{"target_pool" => Serializer.target_pool(pool)})
    end
  end

  def create_member(conn, %{"id" => pool_id} = params) do
    pool = Sim.get_target_pool!(pool_id)

    with {:ok, member} <- Sim.add_target_pool_member(pool, params) do
      conn
      |> put_status(:created)
      |> json(%{"target_pool_member" => Serializer.target_pool_member(member)})
    end
  end
end
