defmodule TradingOptionsSimWeb.Api.TagControllerTest do
  use TradingOptionsSimWeb.ConnCase, async: true

  alias TradingOptionsSim.Sim

  defp token_conn(conn, scopes) do
    {:ok, {raw, _token}} =
      Sim.create_api_token("test-token-#{System.unique_integer([:positive])}", scopes)

    put_req_header(conn, "authorization", "Bearer #{raw}")
  end

  describe "GET /api/v1/tags" do
    test "lists tags", %{conn: conn} do
      {:ok, _tag} = Sim.get_or_create_tag("no exit")

      conn = conn |> token_conn(["tags:read"]) |> get(~p"/api/v1/tags")
      body = json_response(conn, 200)
      assert [%{"name" => "no exit"}] = body["tags"]
    end
  end
end
