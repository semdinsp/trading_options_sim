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

  describe "GET /api/v1/versions/metrics" do
    test "returns one row per discovery/quarantine version with gates", %{conn: conn} do
      version = version_fixture()

      conn = conn |> token_conn(["strategies:read"]) |> get(~p"/api/v1/versions/metrics")
      body = json_response(conn, 200)

      assert [row] =
               Enum.filter(
                 body["candidate_metrics"],
                 &(&1["strategy_version_id"] == version.id)
               )

      assert row["n_closes"] == 0
      assert Map.has_key?(row, "capital_hours")
      assert Map.has_key?(row, "avg_hold_seconds")
      assert Map.has_key?(row, "scored_total_r")
      assert Map.has_key?(row, "final_score")
      assert row["gates"]["sample_floor"] in ["pass", "fail", "not_computed", "not_applicable"]
    end

    # 0_SPEC.md is the authority on this list. A field silently missing
    # from the payload is the failure mode the whole contract exists to
    # prevent -- this app has no MCP server registered on the operator's
    # machine, so GET /api/v1/versions/metrics is its only external
    # surface and there is no second place to notice the gap.
    test "the metrics row ships every field 0_SPEC.md requires", %{conn: conn} do
      version = version_fixture()

      body =
        conn
        |> token_conn(["strategies:read"])
        |> get(~p"/api/v1/versions/metrics")
        |> json_response(200)

      [row] =
        Enum.filter(body["candidate_metrics"], &(&1["strategy_version_id"] == version.id))

      required = ~w(
        strategy_version_id strategy_id version strategy_name lifecycle_stage
        direction target_pool_id target_pool_name
        basis churn r_denominator n_closes excluded_count excluded_pnl
        first_traded_on last_traded_on
        expectancy_r sd_r total_r
        n_sessions mean_daily_r sd_daily_r
        realized_pnl realized_pnl_gross
        required_r cost_basis cost_margin
        capital_hours capital_basis scored_runs scored_runs_coverage
        scored_total_r scored_expectancy_r final_score final_score_scale
        exit_reason_histogram quarantine_trading_days
        lcb95
        schema_version computed_through
      )

      missing = Enum.reject(required, &Map.has_key?(row, &1))
      assert missing == [], "metrics row is missing: #{inspect(missing)}"

      # Constant-per-row population labels, not booleans a consumer has
      # to infer from a docstring.
      assert row["r_denominator"] == "premium_at_risk"
      assert row["capital_basis"] == "premium_at_risk"
      assert row["cost_basis"] == "measured"
      assert row["basis"] == "net"
      assert row["churn"] == "excluded"
      assert row["final_score_scale"] == 1_000_000

      # ucb95/ucb90 are explicitly NOT in the contract -- both are pure
      # derivations of (expectancy_r, sd_r, n_closes), all of which are
      # in the row.
      refute Map.has_key?(row, "ucb95")
      refute Map.has_key?(row, "ucb90")
    end

    test "capital_hours/scored_total_r/final_score serialize as native JSON numbers, not strings",
         %{conn: conn} do
      pool = pool_fixture(["METRICNUM1"])
      version = version_fixture(%{target_pool_id: pool.id})

      {:ok, run} =
        Sim.open_sim_run(version, %{
          symbol: "METRICNUM1",
          expiry: "20271231",
          strike: Decimal.new("150.00"),
          right: "C",
          multiplier: 100,
          direction: "long"
        })

      entry_price = Decimal.new("5.00")
      risk_at_entry = Sim.compute_risk_at_entry(entry_price, 100, 1)
      now = DateTime.utc_now()

      {:ok, {_fill, run}} =
        Sim.record_entry_fill(
          run,
          %{action: "buy", quantity: 1, fill_price: entry_price, filled_at: now},
          %{entry_at: now, entry_price: entry_price, risk_at_entry: risk_at_entry}
        )

      {:ok, {_fill, _run}} =
        Sim.record_exit_fill(
          run,
          %{action: "sell", quantity: 1, fill_price: Decimal.new("6.00"), filled_at: now},
          %{
            exit_at: now,
            exit_price: Decimal.new("6.00"),
            exit_reason: "target_hit",
            realized_pnl: Decimal.new("100.00"),
            realized_pnl_net: Decimal.new("100.00")
          }
        )

      conn = conn |> token_conn(["strategies:read"]) |> get(~p"/api/v1/versions/metrics")
      body = json_response(conn, 200)

      [row] = Enum.filter(body["candidate_metrics"], &(&1["strategy_version_id"] == version.id))

      assert is_number(row["scored_total_r"])
      assert is_float(row["expectancy_r"])
      assert is_float(row["realized_pnl"])
    end

    test "403s without strategies:read scope", %{conn: conn} do
      conn = conn |> token_conn(["tags:write"]) |> get(~p"/api/v1/versions/metrics")
      assert json_response(conn, 403)
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

  describe "POST /api/v1/versions/:id/trading_hours" do
    test "updates trading_hours_policy and overnight_hold", %{conn: conn} do
      version = version_fixture()

      conn =
        conn
        |> token_conn(["strategies:write"])
        |> post(~p"/api/v1/versions/#{version.id}/trading_hours", %{
          "trading_hours_policy" => "unrestricted",
          "overnight_hold" => true
        })

      body = json_response(conn, 200)
      assert body["strategy_version"]["trading_hours_policy"] == "unrestricted"
      assert body["strategy_version"]["overnight_hold"] == true
    end

    test "422s on an invalid trading_hours_policy", %{conn: conn} do
      version = version_fixture()

      conn =
        conn
        |> token_conn(["strategies:write"])
        |> post(~p"/api/v1/versions/#{version.id}/trading_hours", %{
          "trading_hours_policy" => "bogus"
        })

      assert json_response(conn, 422)
    end

    test "403s with strategies:read only", %{conn: conn} do
      version = version_fixture()

      conn =
        conn
        |> token_conn(["strategies:read"])
        |> post(~p"/api/v1/versions/#{version.id}/trading_hours", %{
          "trading_hours_policy" => "unrestricted"
        })

      assert json_response(conn, 403)
    end
  end

  describe "PATCH /api/v1/versions/:id/notes" do
    test "sets notes", %{conn: conn} do
      version = version_fixture()

      conn =
        conn
        |> token_conn(["strategies:write"])
        |> patch(~p"/api/v1/versions/#{version.id}/notes", %{
          "notes" => "Exit on delta decay below 0.30"
        })

      body = json_response(conn, 200)
      assert body["strategy_version"]["notes"] == "Exit on delta decay below 0.30"
    end

    test "403s with strategies:read only", %{conn: conn} do
      version = version_fixture()

      conn =
        conn
        |> token_conn(["strategies:read"])
        |> patch(~p"/api/v1/versions/#{version.id}/notes", %{"notes" => "nope"})

      assert json_response(conn, 403)
    end

    # The fields must be present on EVERY row, not only caveated ones.
    # An absent key is indistinguishable from "this client didn't know
    # to look", which is the exact failure the caveat index exists to
    # close: the answer was already in the payload and nobody could ask
    # for it.
    test "every version row carries caveats and has_open_caveat", %{conn: conn} do
      version = version_fixture()

      row =
        conn
        |> token_conn(["strategies:read"])
        |> get(~p"/api/v1/versions/#{version.id}")
        |> json_response(200)
        |> Map.fetch!("strategy_version")

      assert row["caveats"] == []
      assert row["has_open_caveat"] == false
    end

    test "a caveated note is parsed into queryable entries", %{conn: conn} do
      version = version_fixture()

      notes = """
      CAVEATS FIRST — one live, one permanent.
      (1) HISTORY BEFORE 2026-09-18 IS NOT COMPARABLE: priced at a flat 30% IV.
      (2) DO NOT TRUST THE NAME: R is return-on-premium, not return-on-risk.

      Origin: seeded by hand.
      """

      {:ok, _} = Sim.set_strategy_version_notes(version, notes)

      row =
        conn
        |> token_conn(["strategies:read"])
        |> get(~p"/api/v1/versions/#{version.id}")
        |> json_response(200)
        |> Map.fetch!("strategy_version")

      assert [history, semantic] = row["caveats"]
      assert history["kind"] == "history"
      assert semantic["kind"] == "semantic"

      # :history is actionable, so the row is open. A :semantic caveat
      # alone would not be -- it never clears, and a permanent flag
      # stops being read.
      assert row["has_open_caveat"] == true
    end

    # Was "422s (not 500) when notes exceed 255 characters". That test
    # guarded a real crash path: notes was varchar(255), so an
    # over-length note raised Postgrex 22001 as a 500 unless the
    # changeset caught it first. The column is :text as of migration
    # 20260919120000 (notes now carry structured caveat blocks -- see
    # TradingOptionsSim.Sim.Caveat), so there is no length to violate
    # and the crash path is gone rather than merely handled. Kept,
    # inverted, so a future narrowing of the column fails here loudly
    # instead of silently truncating someone's caveat.
    test "accepts a note far longer than the old 255-char ceiling", %{conn: conn} do
      version = version_fixture()
      long = String.duplicate("a", 4_000)

      conn =
        conn
        |> token_conn(["strategies:write"])
        |> patch(~p"/api/v1/versions/#{version.id}/notes", %{"notes" => long})

      body = json_response(conn, 200)
      assert String.length(body["strategy_version"]["notes"]) == 4_000
    end
  end
end
