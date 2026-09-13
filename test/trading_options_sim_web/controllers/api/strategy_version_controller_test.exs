defmodule TradingOptionsSimWeb.Api.StrategyVersionControllerTest do
  use TradingOptionsSimWeb.ConnCase, async: true

  alias TradingOptionsSim.Sim

  defp token_conn(conn, scopes) do
    {:ok, {raw, _token}} =
      Sim.create_api_token("test-token-#{System.unique_integer([:positive])}", scopes)

    put_req_header(conn, "authorization", "Bearer #{raw}")
  end

  defp version_fixture(attrs \\ %{}) do
    {:ok, strategy} = Sim.create_strategy(%{name: "Test Strategy"})

    {:ok, version} =
      Sim.create_strategy_version(
        strategy,
        Map.merge(%{version: 1, position_sizing: %{"method" => "fixed_qty", "qty" => 1}}, attrs)
      )

    version
  end

  describe "GET /api/v1/versions/:id" do
    test "returns the version", %{conn: conn} do
      version = version_fixture()

      conn = conn |> token_conn(["strategies:read"]) |> get(~p"/api/v1/versions/#{version.id}")
      body = json_response(conn, 200)
      assert body["strategy_version"]["id"] == version.id
      assert body["strategy_version"]["lifecycle_stage"] == "discovery"
    end
  end

  describe "POST /api/v1/versions/:id/promote" do
    test "422s with the invalid-transition error shape when there's no target pool", %{
      conn: conn
    } do
      version = version_fixture()

      conn =
        conn
        |> token_conn(["strategies:write"])
        |> post(~p"/api/v1/versions/#{version.id}/promote", %{"to" => "quarantine"})

      body = json_response(conn, 422)
      assert body["errors"]["target_pool_id"]
    end

    test "promotes to quarantine with a target pool set", %{conn: conn} do
      {:ok, pool} = Sim.create_target_pool(%{name: "Pool"})
      version = version_fixture(%{target_pool_id: pool.id})

      conn =
        conn
        |> token_conn(["strategies:write"])
        |> post(~p"/api/v1/versions/#{version.id}/promote", %{"to" => "quarantine"})

      body = json_response(conn, 200)
      assert body["strategy_version"]["lifecycle_stage"] == "quarantine"
    end

    test "403s with strategies:read only", %{conn: conn} do
      version = version_fixture()

      conn =
        conn
        |> token_conn(["strategies:read"])
        |> post(~p"/api/v1/versions/#{version.id}/promote", %{"to" => "quarantine"})

      assert json_response(conn, 403)
    end
  end

  describe "POST /api/v1/versions/:id/downgrade" do
    test "downgrades to retired with a reason", %{conn: conn} do
      version = version_fixture()

      conn =
        conn
        |> token_conn(["strategies:write"])
        |> post(~p"/api/v1/versions/#{version.id}/downgrade", %{
          "to" => "retired",
          "reason" => "abandoned"
        })

      body = json_response(conn, 200)
      assert body["strategy_version"]["lifecycle_stage"] == "retired"
      assert body["strategy_version"]["retired_reason"] == "abandoned"
    end
  end

  describe "POST /api/v1/versions/:id/promote_to_live_app" do
    test "stamps the outbound promotion marker from test_portfolio", %{conn: conn} do
      {:ok, pool} = Sim.create_target_pool(%{name: "Pool"})
      version = version_fixture(%{target_pool_id: pool.id})
      {:ok, version} = Sim.promote_strategy_version(version, "quarantine")
      {:ok, version} = Sim.promote_strategy_version(version, "test_portfolio")

      live_strategy_id = Ecto.UUID.generate()

      conn =
        conn
        |> token_conn(["strategies:write"])
        |> post(~p"/api/v1/versions/#{version.id}/promote_to_live_app", %{
          "live_app" => "trading_live",
          "live_strategy_id" => live_strategy_id
        })

      body = json_response(conn, 200)
      assert body["strategy_version"]["promoted_to_live_app"] == "trading_live"
      assert body["strategy_version"]["lifecycle_stage"] == "test_portfolio"
    end
  end

  describe "tags" do
    test "PUT /api/v1/versions/:id/tags replaces the tag set", %{conn: conn} do
      version = version_fixture()
      {:ok, tag} = Sim.get_or_create_tag("needs review")

      conn =
        conn
        |> token_conn(["tags:write"])
        |> put(~p"/api/v1/versions/#{version.id}/tags", %{"tag_ids" => [tag.id]})

      assert json_response(conn, 200)
    end

    test "POST /api/v1/versions/:id/tags get-or-creates by name", %{conn: conn} do
      version = version_fixture()

      conn =
        conn
        |> token_conn(["tags:write"])
        |> post(~p"/api/v1/versions/#{version.id}/tags", %{"name" => "no exit"})

      assert json_response(conn, 200)
    end
  end
end
