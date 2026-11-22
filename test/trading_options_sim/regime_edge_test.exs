defmodule TradingOptionsSim.RegimeEdgeTest do
  # async: false: LifecycleReview / SimActivator touch real monitors.
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.{LifecycleReview, RegimeEdge, Repo, Sim}

  describe "inverse_normal_cdf/1 and z_for/1" do
    test "match standard normal quantiles" do
      assert_in_delta RegimeEdge.inverse_normal_cdf(0.5), 0.0, 1.0e-9
      assert_in_delta RegimeEdge.inverse_normal_cdf(0.975), 1.959964, 1.0e-6
      assert_in_delta RegimeEdge.inverse_normal_cdf(0.001), -3.090232, 1.0e-6
      assert_in_delta RegimeEdge.inverse_normal_cdf(0.999), 3.090232, 1.0e-6
    end

    test "one-sided alpha 0.05, Bonferroni-corrected by k" do
      assert_in_delta RegimeEdge.z_for(1), 1.644854, 1.0e-6
      assert_in_delta RegimeEdge.z_for(2), 1.959964, 1.0e-6
      assert_in_delta RegimeEdge.z_for(10), 2.575829, 1.0e-6
    end
  end

  describe "evaluate/1" do
    defp bucket(label, n, s, mean, sd),
      do: %{
        regime_label: label,
        n_closes: n,
        n_sessions: s,
        mean_session_r: mean,
        sd_session_r: sd
      }

    test "only buckets meeting 20 closes / 10 sessions count, and they set k" do
      r =
        RegimeEdge.evaluate([
          bucket("normal|chop", 20, 10, 0.3, 0.2),
          bucket("calm|up", 19, 12, 0.9, 0.1),
          bucket("calm|down", 40, 9, 0.9, 0.1)
        ])

      assert r.k == 1
      assert [%{regime_label: "normal|chop"}] = r.buckets
      # lcb = 0.3 - 1.645 * 0.2 / sqrt(10) = 0.196
      assert [%{regime_label: "normal|chop", lcb95: lcb}] = r.edges
      assert_in_delta lcb, 0.3 - 1.644854 * 0.2 / :math.sqrt(10), 1.0e-6
      assert r.has_edge
    end

    test "no mean-only arm: a high mean with a negative bound is not an edge" do
      r = RegimeEdge.evaluate([bucket("normal|chop", 30, 10, 0.4, 1.5)])
      refute r.has_edge
      assert [%{lcb95: lcb}] = r.buckets
      assert lcb < 0
    end

    test "testing more buckets raises z and can remove an edge" do
      # lcb at k=1: 0.2 - 1.645*0.4/4 = +0.036; at k=3, z = 2.128 -> 0.2 - 0.213 < 0.
      edge = bucket("normal|chop", 30, 16, 0.2, 0.4)
      assert RegimeEdge.evaluate([edge]).has_edge

      r =
        RegimeEdge.evaluate([
          edge,
          bucket("calm|up", 30, 16, -0.2, 0.4),
          bucket("stressed|down", 30, 16, -0.3, 0.4)
        ])

      assert r.k == 3
      refute r.has_edge
    end

    test "uncategorized counts towards k but is never the edge" do
      r = RegimeEdge.evaluate([bucket("uncategorized", 40, 15, 0.5, 0.1)])
      assert r.k == 1
      refute r.has_edge
    end
  end

  # --- DB-backed -----------------------------------------------------------

  defp version_fixture(name) do
    {:ok, pool} = Sim.create_target_pool(%{name: "#{name} Pool"})

    {:ok, _} =
      Sim.add_target_pool_member(pool, %{symbol: "RGE#{System.unique_integer([:positive])}"})

    {:ok, strategy} = Sim.create_strategy(%{name: name})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1},
        target_pool_id: pool.id,
        option_leg_config: %{
          "expiry_selection" => "fixed",
          "fixed_expiry" => "20271231",
          "strike_selection" => "fixed_strike",
          "fixed_strike" => "150.00",
          "right" => "P"
        },
        rules: %{"entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 0}},
        params: %{"min_hold_seconds" => 600}
      })

    {:ok, version} = Sim.mark_activated(version)
    version
  end

  # One closed trade per `{days_ago, net}`, labelled `label` at entry,
  # risk_at_entry $500 (so R = net / 500). No regime ordinals in the
  # entry snapshot, so Sim.best_regime_cell/1 never finds a cell.
  defp add_trades(version, label, trades, opts \\ []) do
    for {days_ago, net} <- trades do
      at = DateTime.utc_now() |> DateTime.add(-days_ago * 86_400, :second)

      {:ok, run} =
        Sim.open_sim_run(version, %{
          symbol: "RGE",
          expiry: "20271231",
          strike: Decimal.new("150.00"),
          right: "P",
          multiplier: 100,
          direction: "long"
        })

      context = if label, do: %{"regime_label" => label}, else: %{}

      {:ok, {_f, run}} =
        Sim.record_entry_fill(
          run,
          %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: at},
          %{
            entry_at: at,
            entry_price: Decimal.new("5.00"),
            risk_at_entry: Decimal.new("500"),
            entry_snapshot: %{},
            context: context
          }
        )

      {:ok, {_exit_fill, run}} =
        Sim.record_exit_fill(
          run,
          %{action: "sell", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: at},
          %{
            exit_at: at,
            exit_price: Decimal.new("5.00"),
            exit_reason: "rule_exit",
            realized_pnl: Decimal.new(net),
            realized_pnl_net: Decimal.new(net)
          }
        )

      if opts[:churn], do: run |> Ecto.Changeset.change(is_churn: true) |> Repo.update!()
    end
  end

  # A loser overall with a real edge in normal|chop: 2 closes a day for 16
  # days at +0.2R/+0.3R there, and 2 closes a day at -0.8R in stressed|down.
  defp add_chop_edge_loser(v) do
    add_trades(v, "normal|chop", for(d <- 1..16, net <- [100, 150], do: {d, net}))
    add_trades(v, "stressed|down", for(d <- 1..16, _ <- 1..2, do: {d, -400}))
  end

  test "Sim.regime_edge/1 finds the edge bucket and reports the agreed shape" do
    v = version_fixture("RGE Edge")
    add_chop_edge_loser(v)

    assert %{has_edge: true, label_basis: "entry", r_basis: "net", k: 2} =
             r = Sim.regime_edge([v.id])[v.id]

    assert [%{regime_label: "normal|chop", n_closes: 32, n_sessions: 16, mean_session_r: m}] =
             r.edges

    assert_in_delta m, 0.25, 1.0e-9
    assert length(r.buckets) == 2
    assert r.overall.n_closes == 64
    assert_in_delta r.overall.mean_session_r, (0.25 - 0.8) / 2, 1.0e-9
    assert Date.diff(r.window.end, r.window.start) == 15
    assert MapSet.member?(Sim.regime_edge_version_ids([v.id]), v.id)
  end

  test "sessions, not closes: one big day split into many closes can't make an edge" do
    v = version_fixture("RGE One Day")
    # 25 winning closes on one day, then 11 days of one small loss each.
    add_trades(v, "normal|chop", for(_ <- 1..25, do: {1, 400}))
    add_trades(v, "normal|chop", for(d <- 2..12, do: {d, -60}))

    r = Sim.regime_edge([v.id])[v.id]
    assert [%{n_closes: 36, n_sessions: 12, mean_session_r: m}] = r.buckets
    # (0.8 + 11 * -0.12) / 12 < 0, though the per-close mean is positive.
    assert m < 0
    refute r.has_edge
  end

  test "churn runs are left out" do
    v = version_fixture("RGE Churn")
    add_trades(v, "normal|chop", for(d <- 1..12, _ <- 1..2, do: {d, 100}), churn: true)
    assert Sim.regime_edge([v.id]) == %{}
  end

  test "LifecycleReview keeps a losing discovery version with a regime edge" do
    v = version_fixture("RGE Discovery Loser")
    add_chop_edge_loser(v)

    a = Enum.find(LifecycleReview.run(mode: :apply), &(&1.version_id == v.id))
    assert a.action == :kept_for_regime_edge
    assert [%{regime_label: "normal|chop"}] = a.regime_edge.edges

    v = Sim.get_strategy_version!(v.id)
    assert v.lifecycle_stage == "discovery"
    assert is_nil(v.deactivated_at)
  end

  test "LifecycleReview still retires a loser whose regime buckets have no proven edge" do
    v = version_fixture("RGE Plain Loser")
    add_trades(v, "normal|chop", for(d <- 1..16, net <- [-50, 20], do: {d, net}))

    a = Enum.find(LifecycleReview.run(mode: :apply), &(&1.version_id == v.id))
    assert a.action == :retire
    assert Sim.get_strategy_version!(v.id).lifecycle_stage == "retired"
  end

  test "quarantine job 3 keeps a failing version with a regime edge" do
    v = version_fixture("RGE Quarantine")
    {:ok, v} = Sim.promote_strategy_version(v, "quarantine")
    {:ok, v} = v |> Ecto.Changeset.change(quarantine_trading_days: 20) |> Repo.update()
    add_chop_edge_loser(v)
    assert Sim.quarantine_failing?(v.id)

    {:ok, retired} = Sim.auto_retire_failing_quarantine_versions()
    refute Enum.any?(retired, &(&1.id == v.id))
    assert Sim.get_strategy_version!(v.id).lifecycle_stage == "quarantine"
  end

  test "GET /api/v1/versions/:id/regime_edge" do
    v = version_fixture("RGE Api")
    add_chop_edge_loser(v)

    {:ok, {raw, _}} =
      Sim.create_api_token("rge-#{System.unique_integer([:positive])}", ["strategies:read"])

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
      |> Phoenix.ConnTest.dispatch(
        TradingOptionsSimWeb.Endpoint,
        :get,
        "/api/v1/versions/#{v.id}/regime_edge"
      )

    body = Phoenix.ConnTest.json_response(conn, 200)
    assert body["has_edge"] == true
    assert body["label_basis"] == "entry"
    assert [%{"regime_label" => "normal|chop", "n_sessions" => 16}] = body["edges"]

    missing =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
      |> Phoenix.ConnTest.dispatch(
        TradingOptionsSimWeb.Endpoint,
        :get,
        "/api/v1/versions/#{Ecto.UUID.generate()}/regime_edge"
      )

    assert missing.status == 404
  end
end
