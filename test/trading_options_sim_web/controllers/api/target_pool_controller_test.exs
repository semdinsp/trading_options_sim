defmodule TradingOptionsSimWeb.Api.TargetPoolControllerTest do
  use TradingOptionsSimWeb.ConnCase, async: true

  alias TradingOptionsSim.Sim

  defp token_conn(conn, scopes) do
    {:ok, {raw, _token}} =
      Sim.create_api_token("test-token-#{System.unique_integer([:positive])}", scopes)

    put_req_header(conn, "authorization", "Bearer #{raw}")
  end

  describe "POST /api/v1/target_pools" do
    test "creates a target pool", %{conn: conn} do
      conn =
        conn
        |> token_conn(["target_pools:write"])
        |> post(~p"/api/v1/target_pools", %{"name" => "Mega Cap Tech"})

      body = json_response(conn, 201)
      assert body["target_pool"]["name"] == "Mega Cap Tech"
    end
  end

  describe "GET /api/v1/target_pools/:id" do
    test "returns the pool with its members", %{conn: conn} do
      {:ok, pool} = Sim.create_target_pool(%{name: "Pool"})
      {:ok, _member} = Sim.add_target_pool_member(pool, %{symbol: "AAPL"})

      conn =
        conn
        |> token_conn(["target_pools:read"])
        |> get(~p"/api/v1/target_pools/#{pool.id}")

      body = json_response(conn, 200)
      assert body["target_pool"]["id"] == pool.id
      assert [%{"symbol" => "AAPL"}] = body["members"]
    end
  end

  describe "POST /api/v1/target_pools/:id/members" do
    test "adds a member to the pool", %{conn: conn} do
      {:ok, pool} = Sim.create_target_pool(%{name: "Pool"})

      conn =
        conn
        |> token_conn(["target_pools:write"])
        |> post(~p"/api/v1/target_pools/#{pool.id}/members", %{"symbol" => "MSFT"})

      body = json_response(conn, 201)
      assert body["target_pool_member"]["symbol"] == "MSFT"
    end
  end
end
