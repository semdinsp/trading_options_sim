defmodule TradingOptionsSimWeb.Api.StrategyControllerTest do
  use TradingOptionsSimWeb.ConnCase, async: true

  alias TradingOptionsSim.Sim

  defp token_conn(conn, scopes) do
    {:ok, {raw, _token}} =
      Sim.create_api_token("test-token-#{System.unique_integer([:positive])}", scopes)

    put_req_header(conn, "authorization", "Bearer #{raw}")
  end

  describe "GET /api/v1/strategies" do
    test "401s with no bearer token", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/strategies")
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "403s with a token lacking strategies:read", %{conn: conn} do
      conn = conn |> token_conn(["tags:read"]) |> get(~p"/api/v1/strategies")
      assert json_response(conn, 403)["error"] == "forbidden"
    end

    test "200s and lists strategies with a valid token", %{conn: conn} do
      {:ok, _strategy} = Sim.create_strategy(%{name: "AAPL Momentum"})

      conn = conn |> token_conn(["strategies:read"]) |> get(~p"/api/v1/strategies")
      body = json_response(conn, 200)
      assert [%{"name" => "AAPL Momentum"}] = body["strategies"]
    end
  end

  describe "POST /api/v1/strategies" do
    test "creates a strategy with strategies:write scope", %{conn: conn} do
      conn =
        conn
        |> token_conn(["strategies:write"])
        |> post(~p"/api/v1/strategies", %{"name" => "New Strategy"})

      body = json_response(conn, 201)
      assert body["strategy"]["name"] == "New Strategy"
    end

    test "422s on missing required fields", %{conn: conn} do
      conn = conn |> token_conn(["strategies:write"]) |> post(~p"/api/v1/strategies", %{})
      assert json_response(conn, 422)
    end
  end

  describe "POST /api/v1/strategies/:id/versions" do
    test "creates a version under the given strategy", %{conn: conn} do
      {:ok, strategy} = Sim.create_strategy(%{name: "Test"})

      conn =
        conn
        |> token_conn(["strategies:write"])
        |> post(~p"/api/v1/strategies/#{strategy.id}/versions", %{
          "version" => 1,
          "position_sizing" => %{"method" => "fixed_qty", "qty" => 1}
        })

      body = json_response(conn, 201)
      assert body["strategy_version"]["strategy_id"] == strategy.id
      assert body["strategy_version"]["lifecycle_stage"] == "discovery"
    end
  end
end
