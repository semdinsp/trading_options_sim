defmodule TradingOptionsSim.Sim.StopSizingTest do
  use TradingOptionsSim.DataCase, async: true

  import Ecto.Query

  alias TradingOptionsSim.Repo
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.{SimRun, StopSizing}
  alias TradingOptionsSim.StopLadder

  defp version_fixture(name \\ nil) do
    name = name || "Stop Sizing #{System.unique_integer([:positive])}"
    {:ok, strategy} = Sim.create_strategy(%{name: name})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    version
  end

  # One closed run, premium 5.00 x 100 = 500 at risk, R = pnl / 500,
  # entered at 15:00 UTC on `day` (a New York session date).
  defp run_fixture(version, day, r, opts \\ []) do
    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: "STZ",
        expiry: "20271231",
        strike: Decimal.new("150.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

    entry_at = DateTime.new!(day, ~T[15:00:00], "Etc/UTC")
    exit_at = DateTime.add(entry_at, 600, :second)
    entry_price = Decimal.new("5.00")
    pnl = Decimal.from_float(r * 500)

    {:ok, {_fill, run}} =
      Sim.record_entry_fill(
        run,
        %{action: "buy", quantity: 1, fill_price: entry_price, filled_at: entry_at},
        %{
          entry_at: entry_at,
          entry_price: entry_price,
          risk_at_entry: Sim.compute_risk_at_entry(entry_price, 100, 1)
        }
      )

    {:ok, {_fill, run}} =
      Sim.record_exit_fill(
        run,
        %{action: "sell", quantity: 1, fill_price: entry_price, filled_at: exit_at},
        %{
          exit_at: exit_at,
          exit_price: Keyword.get(opts, :exit_price, entry_price),
          exit_reason: Keyword.get(opts, :exit_reason, "rule_exit"),
          realized_pnl: pnl,
          realized_pnl_net: pnl
        }
      )

    Repo.update_all(where(SimRun, id: ^run.id),
      set: [context: Keyword.get(opts, :context, %{"regime_label" => "calm|up"})]
    )

    run
  end

  # A complete ladder (no underlying rungs) for `run`; `r_for.(kind, value,
  # with_tp)` gives each rung's R. `drop` leaves rungs out (incomplete).
  defp ladder_fixture(run, version, r_for, opts \\ []) do
    rungs =
      for(v <- StopLadder.premium_rungs(), tp <- [true, false], do: {"premium", v, tp}) ++
        for tp <- [true, false], do: {"time", 15, tp}

    rows =
      rungs
      |> Enum.drop(Keyword.get(opts, :drop, 0))
      |> Enum.map(fn {kind, value, tp} ->
        r = r_for.(kind, value, tp)

        %{
          sim_run_id: run.id,
          strategy_version_id: version.id,
          ladder_version: 1,
          rung_kind: kind,
          rung_value: value && value / 1,
          with_tp: tp,
          exit_price: Decimal.new("5.00"),
          exit_reason: if(r < 0 and kind == "premium" and value, do: "stop", else: "rule"),
          exit_at: run.exit_at,
          underlying_at_exit: 150.0,
          pnl_net: Decimal.from_float(r * 500),
          r_net: r,
          mae_pct: Keyword.get(opts, :mae, 3.0),
          mfe_pct: 1.0
        }
      end)

    Sim.insert_stop_ladder_rows(rows)
  end

  defp days(n), do: for(i <- 1..n, do: Date.add(~D[2026-12-01], i))

  test "suggestion is null when every rung is negative" do
    version = version_fixture()

    for {day, i} <- Enum.with_index(days(12)) do
      run = run_fixture(version, day, -0.1)
      ladder_fixture(run, version, fn _k, _v, _tp -> -0.05 - i * 0.001 end)
    end

    {:ok, report} = StopSizing.stop_sizing(version.id)
    assert report.suggestion.rung == nil
    assert report.suggestion.reason == "every rung has mean R <= 0"
    assert report.suggestion.in_sample
    assert report.actual.n == 12
  end

  test "suggests the rung that beats the real controls, paired by session" do
    version = version_fixture()

    for {day, i} <- Enum.with_index(days(12)) do
      noise = rem(i, 3) * 0.01
      run = run_fixture(version, day, -0.05 + noise)

      ladder_fixture(run, version, fn
        "premium", 20, _tp -> 0.08 + noise
        _k, _v, _tp -> -0.06 + noise
      end)
    end

    {:ok, report} = StopSizing.stop_sizing(version.id)
    assert report.suggestion.rung == "premium:20"
    assert report.suggestion.delta_vs_actual_lcb90 > 0
    assert report.suggestion.in_sample

    rung = Enum.find(report.ladder, &(&1.rung == "premium:20"))
    assert rung.n == 12 and rung.n_sessions == 12
    assert rung.version_id == version.id
    assert_in_delta rung.delta_vs_actual_mean, 0.13, 1.0e-9
  end

  test "no suggestion under min_sessions" do
    version = version_fixture()

    for day <- days(4) do
      run = run_fixture(version, day, -0.05)
      ladder_fixture(run, version, fn _k, _v, _tp -> 0.2 end)
    end

    {:ok, report} = StopSizing.stop_sizing(version.id)
    assert report.suggestion.rung == nil
    assert report.suggestion.reason =~ "fewer than 10 sessions"
  end

  test "runs with no ladder or an incomplete one are counted and left out" do
    version = version_fixture()
    [d1, d2, d3] = days(3)

    full = run_fixture(version, d1, 0.1)
    ladder_fixture(full, version, fn _k, _v, _tp -> 0.1 end)
    partial = run_fixture(version, d2, 0.1)
    ladder_fixture(partial, version, fn _k, _v, _tp -> 0.1 end, drop: 3)
    _pre_ladder = run_fixture(version, d3, 0.1)

    {:ok, report} = StopSizing.stop_sizing(version.id)
    assert report.actual.n == 1
    assert report.caveats.incomplete_ladder_runs == 1
    assert report.caveats.pre_ladder_runs == 1
    assert report.caveats.regime_mix == %{"calm|up" => 1}
  end

  test "with_tp false reads the no-target rungs" do
    version = version_fixture()
    run = run_fixture(version, hd(days(1)), 0.0)
    ladder_fixture(run, version, fn _k, _v, tp -> if tp, do: 0.1, else: -0.1 end)

    {:ok, with_tp} = StopSizing.stop_sizing(version.id, with_tp: true)
    {:ok, no_tp} = StopSizing.stop_sizing(version.id, with_tp: false)
    assert Enum.all?(with_tp.ladder, &(&1.mean_r == 0.1))
    assert Enum.all?(no_tp.ladder, &(&1.mean_r == -0.1))
  end

  test "stop_value sums realised minus shadow R over real stop exits" do
    version = version_fixture()

    run =
      run_fixture(version, hd(days(1)), -0.1,
        exit_reason: "stop_loss",
        exit_price: Decimal.new("4.45"),
        context: %{"shadow_r" => 0.2, "initial_stop_loss_price" => "4.50"}
      )

    ladder_fixture(run, version, fn _k, _v, _tp -> 0.0 end)

    {:ok, report} = StopSizing.stop_sizing(version.id)
    assert report.stop_value.n_exits == 1
    assert_in_delta report.stop_value.sum_realised_minus_shadow_r, -0.3, 1.0e-9
    # Filled 0.05 under a 4.50 stop on a 5.00 entry: -1% of entry.
    assert_in_delta report.stop_value.mean_stop_slippage_pct, -1.0, 1.0e-9
  end

  test "excursion profile splits MAE by eventual winners and losers" do
    version = version_fixture()
    [d1, d2] = days(2)

    win = run_fixture(version, d1, 0.1)
    ladder_fixture(win, version, fn _k, _v, _tp -> 0.1 end, mae: 2.0)
    lose = run_fixture(version, d2, -0.1)
    ladder_fixture(lose, version, fn _k, _v, _tp -> -0.1 end, mae: 12.0)

    {:ok, report} = StopSizing.stop_sizing(version.id)
    profile = report.excursion_profile
    assert profile.n_winners == 1 and profile.n_losers == 1
    assert profile.winners_mae_pct.p50 == 2.0
    assert profile.losers_mae_pct.p50 == 12.0
  end

  test "unknown version" do
    assert StopSizing.stop_sizing(Ecto.UUID.generate()) == {:error, :not_found}
  end

  test "stop_ab_report pairs each arm against A over the common sessions" do
    base = "Stop-AB Test #{System.unique_integer([:positive])}"
    a = version_fixture(base <> " [Stop-AB A: Control]")
    b = version_fixture(base <> " [Stop-AB B: Catastrophe]")

    for v <- [a, b], do: Sim.add_tag_to_strategy_version_by_name(v, "Stop-AB-2026-11-27")

    for day <- days(3) do
      run_fixture(a, day, 0.1)
      run_fixture(b, day, 0.3)
    end

    # A session only B traded is not common.
    run_fixture(b, Date.add(~D[2026-12-01], 9), 5.0)

    {:ok, report} = StopSizing.stop_ab_report()
    assert report.n_common_sessions == 3
    refute report.ready

    arm_b = Enum.find(report.arms, &(&1.arm == "B"))
    assert_in_delta arm_b.paired_vs_a_mean, 0.2, 1.0e-9
    assert arm_b.n_sessions_all == 4
    assert Enum.find(report.arms, &(&1.arm == "A")).paired_vs_a_mean == nil
  end

  test "stop_sizing_all has one row per version with ladder rows" do
    version = version_fixture()
    run = run_fixture(version, hd(days(1)), 0.1)
    ladder_fixture(run, version, fn _k, _v, _tp -> 0.1 end)

    {:ok, rows} = StopSizing.stop_sizing_all()
    row = Enum.find(rows, &(&1.version_id == version.id))
    assert row.n_runs == 1
    assert row.in_sample
    assert {:error, :invalid_stage} = StopSizing.stop_sizing_all(stage: "nope")
  end
end
