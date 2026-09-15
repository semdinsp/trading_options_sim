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

  defp pool_fixture(symbols) do
    {:ok, pool} = Sim.create_target_pool(%{name: "Pool #{System.unique_integer([:positive])}"})

    Enum.each(symbols, fn symbol ->
      {:ok, _member} = Sim.add_target_pool_member(pool, %{symbol: symbol})
    end)

    Sim.get_target_pool!(pool.id)
  end

  defp fixed_leg_config do
    %{
      "expiry_selection" => "fixed",
      "fixed_expiry" => "20271231",
      "strike_selection" => "fixed_strike",
      "fixed_strike" => "150.00",
      "right" => "C"
    }
  end

  describe "GET /api/v1/versions" do
    test "lists versions with pagination metadata", %{conn: conn} do
      for v <- 1..3, do: version_fixture(%{version: v})

      conn = conn |> token_conn(["strategies:read"]) |> get(~p"/api/v1/versions?limit=2&offset=0")
      body = json_response(conn, 200)

      assert length(body["strategy_versions"]) == 2
      assert body["total_count"] == 3
      assert body["limit"] == 2
      assert body["offset"] == 0
    end

    test "filters by stage", %{conn: conn} do
      version_fixture(%{version: 1})

      conn = conn |> token_conn(["strategies:read"]) |> get(~p"/api/v1/versions?stage=retired")
      body = json_response(conn, 200)

      assert body["strategy_versions"] == []
      assert body["total_count"] == 0
    end

    test "includes tags and activation timestamps", %{conn: conn} do
      version = version_fixture()

      conn = conn |> token_conn(["strategies:read"]) |> get(~p"/api/v1/versions")
      body = json_response(conn, 200)

      assert [entry] = body["strategy_versions"]
      assert entry["id"] == version.id
      assert entry["tags"] == []
      assert Map.has_key?(entry, "activated_at")
      assert Map.has_key?(entry, "deactivated_at")
    end

    test "403s without strategies:read scope", %{conn: conn} do
      conn = conn |> token_conn(["tags:write"]) |> get(~p"/api/v1/versions")
      assert json_response(conn, 403)
    end
  end

  describe "POST /api/v1/versions/:id/activate and deactivate" do
    test "activates a version with a target pool and fixed leg config, then deactivates", %{
      conn: conn
    } do
      pool = pool_fixture(["RCACT1"])

      version =
        version_fixture(%{target_pool_id: pool.id, option_leg_config: fixed_leg_config()})

      conn1 =
        conn
        |> token_conn(["strategies:write"])
        |> post(~p"/api/v1/versions/#{version.id}/activate")

      body1 = json_response(conn1, 200)
      assert body1["monitors_running"] == 1
      assert body1["unsubscribed_symbols"] == []

      conn2 =
        conn
        |> token_conn(["strategies:write"])
        |> post(~p"/api/v1/versions/#{version.id}/deactivate")

      body2 = json_response(conn2, 200)
      assert body2["monitors_stopped"] == 1
    end

    test "403s without strategies:write scope", %{conn: conn} do
      version = version_fixture()

      conn =
        conn
        |> token_conn(["strategies:read"])
        |> post(~p"/api/v1/versions/#{version.id}/activate")

      assert json_response(conn, 403)
    end
  end

  describe "DELETE /api/v1/versions/:id/tags/:tag_id" do
    test "removes an applied tag", %{conn: conn} do
      version = version_fixture()
      {:ok, tag} = Sim.get_or_create_tag("needs review")
      {:ok, version} = Sim.put_strategy_version_tags(version, [tag.id])
      assert Enum.any?(version.tags, &(&1.id == tag.id))

      conn =
        conn
        |> token_conn(["tags:write"])
        |> delete(~p"/api/v1/versions/#{version.id}/tags/#{tag.id}")

      body = json_response(conn, 200)
      refute Enum.any?(body["strategy_version"]["tags"], &(&1["id"] == tag.id))
    end

    test "is a no-op when the tag isn't currently applied", %{conn: conn} do
      version = version_fixture()
      {:ok, tag} = Sim.get_or_create_tag("unused tag")

      conn =
        conn
        |> token_conn(["tags:write"])
        |> delete(~p"/api/v1/versions/#{version.id}/tags/#{tag.id}")

      assert json_response(conn, 200)
    end
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

  describe "POST /api/v1/versions/:id/link_live_strategy" do
    test "links a test_portfolio version to a live_strategy_app", %{conn: conn} do
      {:ok, pool} = Sim.create_target_pool(%{name: "Pool"})
      version = version_fixture(%{target_pool_id: pool.id})
      {:ok, version} = Sim.promote_strategy_version(version, "quarantine")
      {:ok, version} = Sim.promote_strategy_version(version, "test_portfolio")

      live_strategy_id = Ecto.UUID.generate()

      conn =
        conn
        |> token_conn(["strategies:write"])
        |> post(~p"/api/v1/versions/#{version.id}/link_live_strategy", %{
          "live_strategy_app" => "trading_live",
          "live_strategy_id" => live_strategy_id
        })

      body = json_response(conn, 200)
      assert body["strategy_version"]["live_strategy_app"] == "trading_live"
      assert body["strategy_version"]["live_strategy_active"] == true
      assert body["strategy_version"]["lifecycle_stage"] == "test_portfolio"
    end
  end

  describe "POST /api/v1/versions/:id/unlink_live_strategy" do
    test "unlinks a currently-linked version", %{conn: conn} do
      {:ok, pool} = Sim.create_target_pool(%{name: "Pool"})
      version = version_fixture(%{target_pool_id: pool.id})
      {:ok, version} = Sim.promote_strategy_version(version, "quarantine")
      {:ok, version} = Sim.promote_strategy_version(version, "test_portfolio")
      {:ok, version} = Sim.link_live_strategy(version, "trading_live", Ecto.UUID.generate())

      conn =
        conn
        |> token_conn(["strategies:write"])
        |> post(~p"/api/v1/versions/#{version.id}/unlink_live_strategy")

      body = json_response(conn, 200)
      assert body["strategy_version"]["live_strategy_active"] == false
    end

    test "422s when not currently linked", %{conn: conn} do
      version = version_fixture()

      conn =
        conn
        |> token_conn(["strategies:write"])
        |> post(~p"/api/v1/versions/#{version.id}/unlink_live_strategy")

      assert json_response(conn, 422)
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
