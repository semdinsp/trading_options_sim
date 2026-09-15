defmodule TradingOptionsSimWeb.Api.RunControllerTest do
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

  defp run_fixture(version, attrs \\ %{}) do
    {:ok, run} =
      Sim.open_sim_run(
        version,
        Map.merge(
          %{
            symbol: "AAPL",
            expiry: "20270115",
            strike: Decimal.new("150.00"),
            right: "C",
            multiplier: 100,
            direction: "long"
          },
          attrs
        )
      )

    run
  end

  describe "GET /api/v1/runs" do
    test "lists runs with pagination metadata", %{conn: conn} do
      version = version_fixture()
      for _ <- 1..3, do: run_fixture(version)

      conn = conn |> token_conn(["runs:read"]) |> get(~p"/api/v1/runs?limit=2&offset=0")
      body = json_response(conn, 200)

      assert length(body["sim_runs"]) == 2
      assert body["total_count"] == 3
      assert body["limit"] == 2
      assert body["offset"] == 0
    end

    test "filters by status", %{conn: conn} do
      version = version_fixture()
      run_fixture(version)

      conn = conn |> token_conn(["runs:read"]) |> get(~p"/api/v1/runs?status=closed")
      body = json_response(conn, 200)

      assert body["sim_runs"] == []
      assert body["total_count"] == 0
    end

    test "includes tags in each serialized run", %{conn: conn} do
      version = version_fixture()
      run = run_fixture(version)
      {:ok, _run} = Sim.add_tag_to_run_by_name(run, "watch closely")

      conn = conn |> token_conn(["runs:read"]) |> get(~p"/api/v1/runs")
      body = json_response(conn, 200)

      assert [%{"tags" => tags}] = body["sim_runs"]
      assert Enum.any?(tags, &(&1["name"] == "watch closely"))
    end

    test "403s without runs:read scope", %{conn: conn} do
      conn = conn |> token_conn(["strategies:read"]) |> get(~p"/api/v1/runs")
      assert json_response(conn, 403)
    end
  end

  describe "GET /api/v1/runs/:id" do
    test "returns the run", %{conn: conn} do
      version = version_fixture()
      run = run_fixture(version)

      conn = conn |> token_conn(["runs:read"]) |> get(~p"/api/v1/runs/#{run.id}")
      body = json_response(conn, 200)

      assert body["sim_run"]["id"] == run.id
      assert body["sim_run"]["symbol"] == "AAPL"
    end

    test "403s without runs:read scope", %{conn: conn} do
      version = version_fixture()
      run = run_fixture(version)

      conn = conn |> token_conn(["strategies:read"]) |> get(~p"/api/v1/runs/#{run.id}")
      assert json_response(conn, 403)
    end
  end
end
