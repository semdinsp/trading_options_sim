defmodule TradingOptionsSim.Sim.ExpectancyByRegimeTest do
  use TradingOptionsSim.DataCase, async: true

  import Ecto.Query

  alias TradingOptionsSim.Repo
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.{SimRun, StrategyVersion}

  defp version_fixture(stage \\ "discovery") do
    {:ok, strategy} = Sim.create_strategy(%{name: "Regime #{System.unique_integer([:positive])}"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    Repo.update_all(where(StrategyVersion, id: ^version.id), set: [lifecycle_stage: stage])
    %{version | lifecycle_stage: stage}
  end

  # One closed, entered run: premium 5.00 x 100 = 500 at risk, so
  # R = pnl / 500. `regime: nil` leaves context without a regime_label.
  defp run_fixture(version, pnl, opts) do
    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: "RGM",
        expiry: "20271231",
        strike: Decimal.new("150.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

    exit_at = Keyword.get(opts, :exit_at, ~U[2026-10-05 15:00:00Z])
    entry_at = DateTime.add(exit_at, -600, :second)
    entry_price = Decimal.new("5.00")

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

    pnl = Decimal.new(pnl)

    {:ok, {_fill, run}} =
      Sim.record_exit_fill(
        run,
        %{action: "sell", quantity: 1, fill_price: entry_price, filled_at: exit_at},
        %{
          exit_at: exit_at,
          exit_price: entry_price,
          exit_reason: "rule_exit",
          realized_pnl: pnl,
          realized_pnl_net: pnl
        }
      )

    context = if r = Keyword.get(opts, :regime), do: %{"regime_label" => r}, else: %{}

    Repo.update_all(where(SimRun, id: ^run.id),
      set: [
        context: context,
        is_churn: Keyword.get(opts, :churn, false),
        excluded_reason: Keyword.get(opts, :excluded)
      ]
    )

    run
  end

  defp row_for(version) do
    {:ok, [row]} = Sim.expectancy_by_regime(version_id: version.id)
    row
  end

  defp bucket(row, label), do: Enum.find(row.buckets, &(&1.regime_label == label))

  defp metrics_for(version),
    do: Enum.find(Sim.full_universe_version_metrics(), &(&1.strategy_version_id == version.id))

  setup do
    version = version_fixture()
    day1 = ~U[2026-10-05 15:00:00Z]
    day2 = ~U[2026-10-06 15:00:00Z]

    run_fixture(version, "100", regime: "calm|up", exit_at: day1)
    run_fixture(version, "50", regime: "calm|up", exit_at: day2)
    run_fixture(version, "-30", regime: "calm|up", exit_at: day2)
    run_fixture(version, "-20", regime: "normal|chop")
    run_fixture(version, "40", regime: "normal|chop")
    run_fixture(version, "10", regime: nil)
    # In all_trades only
    run_fixture(version, "-400", regime: "calm|up", churn: true)
    run_fixture(version, "-300", regime: "normal|chop", excluded: "stale_ibkr_data")

    %{version: version}
  end

  test "buckets by regime, keeps unlabeled runs as uncategorized, and sums to the candidate metrics",
       %{version: version} do
    row = row_for(version)
    metrics = metrics_for(version)

    assert Enum.map(row.buckets, & &1.regime_label) == ["calm|up", "normal|chop", "uncategorized"]

    assert Enum.sum(Enum.map(row.buckets, & &1.n)) == metrics.scored_runs

    bucket_total_r =
      row.buckets |> Enum.map(& &1.total_r) |> Enum.reduce(&Decimal.add/2)

    assert Decimal.equal?(bucket_total_r, metrics.scored_total_r)

    # total reproduces list_candidate_metrics exactly
    assert row.total.n == metrics.scored_runs
    assert Decimal.equal?(row.total.total_r, metrics.scored_total_r)
    assert Decimal.equal?(row.total.expectancy_r, metrics.expectancy_r)
    assert Decimal.equal?(row.total.realized_pnl_net, metrics.realized_pnl)

    calm = bucket(row, "calm|up")
    assert calm.n == 3
    assert calm.n_sessions == 2
    assert Decimal.equal?(calm.total_r, Decimal.new("0.24"))
    assert Decimal.equal?(calm.expectancy_r, Decimal.new("0.08"))
    assert calm.win_rate == 2 / 3

    assert calm.lcb90 ==
             TradingCore.Stats.lower_bound(calm.expectancy_r, calm.sd_r, calm.n, :p90)

    assert Decimal.compare(calm.lcb90, calm.expectancy_r) == :lt
  end

  test "an n = 1 bucket has nil expectancy_r, sd_r and lcb90 but a real n", %{version: version} do
    uncategorized = version |> row_for() |> bucket("uncategorized")

    assert uncategorized.n == 1
    assert uncategorized.n_sessions == 1
    assert Decimal.equal?(uncategorized.total_r, Decimal.new("0.02"))
    assert uncategorized.expectancy_r == nil
    assert uncategorized.sd_r == nil
    assert uncategorized.lcb90 == nil
  end

  test "churned and excluded runs count in all_trades but not the top-level stats",
       %{version: version} do
    row = row_for(version)

    calm = bucket(row, "calm|up")
    assert calm.n == 3
    assert calm.all_trades.n == 4
    assert Decimal.equal?(calm.all_trades.total_r, Decimal.new("-0.56"))

    chop = bucket(row, "normal|chop")
    assert chop.n == 2
    assert chop.all_trades.n == 3

    assert row.total.n == 6
    assert row.total.all_trades.n == 8
  end

  test "a label holding only churned runs still appears, with n = 0 at the top level" do
    version = version_fixture()
    run_fixture(version, "-50", regime: "stressed|down", churn: true)

    [b] = row_for(version).buckets
    assert b.regime_label == "stressed|down"
    assert b.n == 0
    assert b.total_r == nil
    assert b.all_trades.n == 1
  end

  test "all-versions mode respects the stage filter and skips versions with no closed run",
       %{version: discovery} do
    quarantine = version_fixture("quarantine")
    run_fixture(quarantine, "25", regime: "calm|up")
    no_runs = version_fixture("quarantine")

    {:ok, rows} = Sim.expectancy_by_regime(stage: "quarantine")
    ids = Enum.map(rows, & &1.strategy_version_id)
    assert quarantine.id in ids
    refute discovery.id in ids
    refute no_runs.id in ids

    {:ok, all} = Sim.expectancy_by_regime()
    all_ids = Enum.map(all, & &1.strategy_version_id)
    assert discovery.id in all_ids and quarantine.id in all_ids

    # A blank stage (e.g. `?stage=`) means no filter, not an invalid one
    {:ok, blank} = Sim.expectancy_by_regime(stage: "", version_id: "")
    assert Enum.map(blank, & &1.strategy_version_id) == all_ids
  end

  test "errors for an unknown version, a non-UUID id and an unknown stage" do
    assert {:error, :not_found} = Sim.expectancy_by_regime(version_id: Ecto.UUID.generate())
    assert {:error, :not_found} = Sim.expectancy_by_regime(version_id: "not-a-uuid")
    assert {:error, :invalid_stage} = Sim.expectancy_by_regime(stage: "live")
  end

  test "list_sim_runs_page filters by strategy_version_id", %{version: version} do
    other = version_fixture()
    run_fixture(other, "5", regime: "calm|up")

    {runs, total} = Sim.list_sim_runs_page(nil, strategy_version_id: version.id, limit: 100)
    assert total == 8
    assert Enum.all?(runs, &(&1.strategy_version_id == version.id))

    assert {[], 0} = Sim.list_sim_runs_page(nil, strategy_version_id: "not-a-uuid")
  end
end
