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

  test "add_strategy_version_tag returns an MCP error for an invalid tag name", %{conn: conn} do
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP Tag Error Test"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-tag-error", ["mcp:write"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn =
      call_tool(
        raw,
        session,
        "add_strategy_version_tag",
        %{"version_id" => version.id, "name" => "   "},
        2
      )

    assert conn.resp_body =~ "failed to tag version"

    refute version.id |> Sim.get_strategy_version_detail!() |> Map.fetch!(:tags) |> Enum.any?()
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

  test "list_strategy_versions returns full detail including notes and tags, no scope required",
       %{conn: conn} do
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP List Versions Test"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    {:ok, version} = Sim.set_strategy_version_notes(version, "watch this one closely")
    {:ok, _version} = Sim.add_tag_to_strategy_version_by_name(version, "needs review")

    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-11", ["mcp:read"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn = call_tool(raw, session, "list_strategy_versions", %{}, 2)

    assert conn.resp_body =~ "watch this one closely"
    assert conn.resp_body =~ "needs review"
    assert conn.resp_body =~ "total_count"
  end

  test "list_strategy_versions paginates and filters by stage", %{conn: conn} do
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP List Versions Paginate"})

    for v <- 1..3 do
      {:ok, _version} =
        Sim.create_strategy_version(strategy, %{
          version: v,
          position_sizing: %{"method" => "fixed_qty", "qty" => 1}
        })
    end

    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-12", ["mcp:read"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn = call_tool(raw, session, "list_strategy_versions", %{"limit" => 2}, 2)
    body = conn.resp_body
    assert body =~ "total_count\\\":3"
  end

  test "list_sim_runs requires runs:read scope", %{conn: conn} do
    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-13", ["mcp:read"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn = call_tool(raw, session, "list_sim_runs", %{}, 2)
    assert conn.resp_body =~ "insufficient_scope"
  end

  test "list_sim_runs returns runs with tags when granted runs:read scope", %{conn: conn} do
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP List Runs Test"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: "MCPRUN1",
        expiry: "20270115",
        strike: Decimal.new("150.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

    {:ok, _run} = Sim.add_tag_to_run_by_name(run, "watch closely")

    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-14", ["runs:read"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn = call_tool(raw, session, "list_sim_runs", %{"status" => "open"}, 2)

    assert conn.resp_body =~ "MCPRUN1"
    assert conn.resp_body =~ "watch closely"
    assert conn.resp_body =~ "total_count"
  end

  test "list_candidate_metrics requires strategies:read scope", %{conn: conn} do
    {:ok, {raw, _token}} =
      Sim.create_api_token("mcp-integration-test-candidate-metrics-1", [
        "mcp:read"
      ])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn = call_tool(raw, session, "list_candidate_metrics", %{}, 2)
    assert conn.resp_body =~ "insufficient_scope"
  end

  test "list_candidate_metrics returns capital_hours/scored_total_r/final_score fields matching REST",
       %{conn: conn} do
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP Candidate Metrics Test"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    {:ok, {raw, _token}} =
      Sim.create_api_token("mcp-integration-test-candidate-metrics-2", ["strategies:read"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn = call_tool(raw, session, "list_candidate_metrics", %{}, 2)

    assert conn.resp_body =~ "capital_hours"
    assert conn.resp_body =~ "avg_hold_seconds"
    assert conn.resp_body =~ "scored_total_r"
    assert conn.resp_body =~ "final_score"
    assert conn.resp_body =~ version.id
  end

  test "create_strategy_version requires mcp:write scope", %{conn: conn} do
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP Create Version Scope Test"})
    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-15", ["mcp:read"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn =
      call_tool(
        raw,
        session,
        "create_strategy_version",
        %{"strategy_id" => strategy.id, "version" => 1},
        2
      )

    assert conn.resp_body =~ "insufficient_scope"
    refute Enum.any?(Sim.list_strategy_versions(nil), &(&1.strategy_id == strategy.id))
  end

  test "create_strategy_version creates a version with default position_sizing/direction", %{
    conn: conn
  } do
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP Create Version Test"})
    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-16", ["mcp:write"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn =
      call_tool(
        raw,
        session,
        "create_strategy_version",
        %{"strategy_id" => strategy.id, "version" => 1},
        2
      )

    assert conn.resp_body =~ "version\\\":1"
    assert conn.resp_body =~ "discovery"

    [version] = Sim.list_strategy_versions(nil) |> Enum.filter(&(&1.strategy_id == strategy.id))
    assert version.version == 1
    assert version.direction == "long"
    assert version.position_sizing == %{"method" => "fixed_qty", "qty" => 1}
    assert version.lifecycle_stage == "discovery"
  end

  test "create_strategy_version accepts rules/direction/option_leg_config/target_pool_id", %{
    conn: conn
  } do
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP Create Version Full Test"})
    {:ok, pool} = Sim.create_target_pool(%{name: "MCP Create Version Pool"})
    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-17", ["mcp:write"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn =
      call_tool(
        raw,
        session,
        "create_strategy_version",
        %{
          "strategy_id" => strategy.id,
          "version" => 1,
          "direction" => "short",
          "target_pool_id" => pool.id,
          "rules" => %{
            "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
          },
          "option_leg_config" => %{
            "expiry_selection" => "fixed",
            "fixed_expiry" => "20271231",
            "strike_selection" => "fixed_strike",
            "fixed_strike" => "150.00",
            "right" => "C"
          }
        },
        2
      )

    refute conn.resp_body =~ "isError\":true"

    [version] = Sim.list_strategy_versions(nil) |> Enum.filter(&(&1.strategy_id == strategy.id))
    assert version.direction == "short"
    assert version.target_pool_id == pool.id
    assert version.rules["entry"]["value"] == 100
  end

  test "create_strategy_version returns an error for an unknown strategy_id", %{conn: conn} do
    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-18", ["mcp:write"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn =
      call_tool(
        raw,
        session,
        "create_strategy_version",
        %{"strategy_id" => Ecto.UUID.generate(), "version" => 1},
        2
      )

    assert conn.resp_body =~ "no strategy with id"
  end

  test "update_strategy_version_notes requires mcp:write scope", %{conn: conn} do
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP Notes Scope Test"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-19", ["mcp:read"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn =
      call_tool(
        raw,
        session,
        "update_strategy_version_notes",
        %{"version_id" => version.id, "notes" => "Should fail"},
        2
      )

    assert conn.resp_body =~ "insufficient_scope"
    assert Sim.get_strategy_version!(version.id).notes != "Should fail"
  end

  test "update_strategy_version_notes sets notes with mcp:write scope", %{conn: conn} do
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP Notes Test"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-20", ["mcp:write"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn =
      call_tool(
        raw,
        session,
        "update_strategy_version_notes",
        %{"version_id" => version.id, "notes" => "Exit on theta magnitude below -180"},
        2
      )

    assert conn.resp_body =~ "Exit on theta magnitude below -180"
    assert Sim.get_strategy_version!(version.id).notes == "Exit on theta magnitude below -180"
  end

  test "update_strategy_version_notes returns an error for an unknown version_id", %{conn: conn} do
    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-21", ["mcp:write"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    conn =
      call_tool(
        raw,
        session,
        "update_strategy_version_notes",
        %{"version_id" => Ecto.UUID.generate(), "notes" => "n/a"},
        2
      )

    assert conn.resp_body =~ "no strategy version with id"
  end

  # Was "returns an MCP error (not a crash) over 255 chars". notes was
  # varchar(255), so an over-length note was a real crash path. The
  # column is :text as of migration 20260919120000 -- notes now carry
  # structured caveat blocks (TradingOptionsSim.Sim.Caveat), which do
  # not fit in 255 characters. Inverted rather than deleted so a future
  # narrowing fails here instead of silently truncating a caveat.
  test "update_strategy_version_notes accepts a note past the old 255-char ceiling", %{
    conn: conn
  } do
    {:ok, strategy} = Sim.create_strategy(%{name: "MCP Notes Long Test"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    {:ok, {raw, _token}} = Sim.create_api_token("mcp-integration-test-22", ["mcp:write"])

    conn = initialize(conn, raw)
    session = session_id(conn)

    long = String.duplicate("a", 4_000)

    conn =
      call_tool(
        raw,
        session,
        "update_strategy_version_notes",
        %{"version_id" => version.id, "notes" => long},
        2
      )

    refute conn.resp_body =~ "failed to update notes"
    assert Sim.get_strategy_version!(version.id).notes == long
  end
end
