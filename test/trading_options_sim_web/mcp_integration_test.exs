defmodule TradingOptionsSimWeb.MCPIntegrationTest do
  @moduledoc """
  End-to-end coverage of the real `/mcp` HTTP transport (auth, session
  handshake) — the wiring `TradingOptionsSim.MCP.Tools.*`'s own logic
  doesn't exercise on its own. `async: false` and shared sandbox mode are
  required: `Anubis.Server.Transport.StreamableHTTP.Plug` spawns a
  separate session process per connection to actually handle each
  request, not the test process itself. Ported from
  `TradingSystemWeb.MCPIntegrationTest`.
  """

  use TradingOptionsSimWeb.ConnCase, async: false

  alias TradingOptionsSim.Sim

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(TradingOptionsSim.Repo, {:shared, self()})
    :ok
  end

  defp initialize(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> post("/mcp", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1.0"}
      }
    })
  end

  defp session_id(conn), do: List.first(get_resp_header(conn, "mcp-session-id"))

  defp call_tool(token, session, name, arguments, id) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-session-id", session)
    |> post("/mcp", %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    })
  end

  test "an unauthenticated request is rejected with 401", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    assert conn.status == 401
  end

  test "a valid token can initialize a session and list strategies", %{conn: conn} do
    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test", ["mcp:read"])

    conn = initialize(conn, raw)
    assert conn.status == 200
    session = session_id(conn)
    assert session

    conn = call_tool(raw, session, "list_strategies", %{}, 2)
    assert conn.resp_body =~ "strategies"
  end

  test "list_strategies returns a created strategy's summary", %{conn: conn} do
    {:ok, _strategy} = Sim.create_strategy(%{name: "MCP Test Strategy"})

    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-2", ["mcp:read"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn = call_tool(raw, session, "list_strategies", %{}, 2)
    assert conn.resp_body =~ "MCP Test Strategy"
  end

  test "create_strategy requires mcp:write scope", %{conn: conn} do
    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-3", ["mcp:read"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn = call_tool(raw, session, "create_strategy", %{"name" => "Should Fail"}, 2)
    assert conn.resp_body =~ "insufficient_scope"
    refute Enum.any?(Sim.list_strategies(), &(&1.name == "Should Fail"))
  end

  test "create_strategy succeeds with mcp:write scope", %{conn: conn} do
    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-4", ["mcp:write"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn = call_tool(raw, session, "create_strategy", %{"name" => "MCP Created"}, 2)
    assert conn.resp_body =~ "MCP Created"
    assert Enum.any?(Sim.list_strategies(), &(&1.name == "MCP Created"))
  end

  test "promote_version transitions a version through the lifecycle", %{conn: conn} do
    {:ok, pool} = Sim.create_target_pool(%{name: "MCP Pool"})
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP Promote Test"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1},
        target_pool_id: pool.id
      })

    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-5", ["mcp:write"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn =
      call_tool(
        raw,
        session,
        "promote_version",
        %{"version_id" => version.id, "to" => "quarantine"},
        2
      )

    assert conn.resp_body =~ "quarantine"

    updated = Sim.get_strategy_version!(version.id)
    assert updated.lifecycle_stage == "quarantine"
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

  test "activate_version starts monitors for every target-pool member", %{conn: conn} do
    {:ok, pool} = Sim.create_target_pool(%{name: "MCP Activate Pool"})
    {:ok, _member} = Sim.add_target_pool_member(pool, %{symbol: "MCPACT1"})
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP Activate Test"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1},
        target_pool_id: pool.id,
        option_leg_config: fixed_leg_config()
      })

    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-6", ["mcp:write"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn = call_tool(raw, session, "activate_version", %{"version_id" => version.id}, 2)

    assert conn.resp_body =~ "monitors_running"
    assert MapSet.member?(Sim.active_strategy_version_ids(), version.id)
  end

  test "activate_version returns an error for a version with no target pool", %{conn: conn} do
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP Activate No Pool"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-7", ["mcp:write"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn = call_tool(raw, session, "activate_version", %{"version_id" => version.id}, 2)

    assert conn.resp_body =~ "target_pool_id"
    refute MapSet.member?(Sim.active_strategy_version_ids(), version.id)
  end

  test "activate_version requires mcp:write scope", %{conn: conn} do
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP Activate Scope"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-8", ["mcp:read"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn = call_tool(raw, session, "activate_version", %{"version_id" => version.id}, 2)
    assert conn.resp_body =~ "insufficient_scope"
  end

  test "deactivate_version stops running monitors", %{conn: conn} do
    {:ok, pool} = Sim.create_target_pool(%{name: "MCP Deactivate Pool"})
    {:ok, _member} = Sim.add_target_pool_member(pool, %{symbol: "MCPDEACT1"})
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP Deactivate Test"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1},
        target_pool_id: pool.id,
        option_leg_config: fixed_leg_config()
      })

    {:ok, _pids, []} = TradingOptionsSim.SimActivator.activate(version)

    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-9", ["mcp:write"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn = call_tool(raw, session, "deactivate_version", %{"version_id" => version.id}, 2)

    assert conn.resp_body =~ "monitors_stopped"
    refute MapSet.member?(Sim.active_strategy_version_ids(), version.id)
  end

  test "deactivate_version requires mcp:write scope", %{conn: conn} do
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP Deactivate Scope"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-10", ["mcp:read"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn = call_tool(raw, session, "deactivate_version", %{"version_id" => version.id}, 2)
    assert conn.resp_body =~ "insufficient_scope"
  end
end
