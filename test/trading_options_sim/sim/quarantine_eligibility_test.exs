defmodule TradingOptionsSim.Sim.QuarantineEligibilityTest do
  use TradingOptionsSim.DataCase, async: true

  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.Workers.QuarantineEligibilityWorker

  use Oban.Testing, repo: TradingOptionsSim.Repo

  defp strategy_fixture do
    {:ok, strategy} = Sim.create_strategy(%{name: "Test Strategy"})
    strategy
  end

  defp version_fixture(strategy, attrs \\ %{}) do
    {:ok, version} =
      Sim.create_strategy_version(
        strategy,
        Map.merge(%{version: 1, position_sizing: %{"method" => "fixed_qty", "qty" => 1}}, attrs)
      )

    version
  end

  defp target_pool_fixture do
    {:ok, pool} = Sim.create_target_pool(%{name: "Test Pool"})
    pool
  end

  # Inserts a closed sim_run directly (bypassing ContractMonitor/fill
  # recording) since these tests only care about the aggregate
  # realized_pnl a closed run leaves behind, not the fill mechanics.
  defp closed_run_fixture(version, realized_pnl, exit_at \\ DateTime.utc_now()) do
    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: "TEST",
        expiry: "20271231",
        strike: Decimal.new("150.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

    now = DateTime.utc_now()

    {:ok, {_fill, run}} =
      Sim.record_entry_fill(
        run,
        %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: now},
        %{entry_at: now, entry_price: Decimal.new("5.00")}
      )

    {:ok, {_fill, run}} =
      Sim.record_exit_fill(
        run,
        %{action: "sell", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: exit_at},
        %{
          exit_at: exit_at,
          exit_price: Decimal.new("5.00"),
          exit_reason: "rule_exit",
          realized_pnl: realized_pnl
        }
      )

    run
  end

  describe "update_quarantine_trading_days/1" do
    test "increments quarantine_trading_days for a version with a run that closed on the given date" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})
      {:ok, version} = Sim.promote_strategy_version(version, "quarantine")

      today = Date.utc_today()
      closed_run_fixture(version, Decimal.new("10.00"), DateTime.new!(today, ~T[15:00:00]))

      :ok = Sim.update_quarantine_trading_days(today)

      updated = Sim.get_strategy_version!(version.id)
      assert updated.quarantine_trading_days == 1
      assert updated.quarantine_last_counted_date == today
    end

    test "does not increment for a version with no run closed on the given date" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})
      {:ok, version} = Sim.promote_strategy_version(version, "quarantine")

      today = Date.utc_today()
      :ok = Sim.update_quarantine_trading_days(today)

      updated = Sim.get_strategy_version!(version.id)
      assert updated.quarantine_trading_days == 0
      assert updated.quarantine_last_counted_date == today
    end

    test "is idempotent — re-running for the same already-counted date does not double-increment" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})
      {:ok, version} = Sim.promote_strategy_version(version, "quarantine")

      today = Date.utc_today()
      closed_run_fixture(version, Decimal.new("10.00"), DateTime.new!(today, ~T[15:00:00]))

      :ok = Sim.update_quarantine_trading_days(today)
      :ok = Sim.update_quarantine_trading_days(today)

      assert Sim.get_strategy_version!(version.id).quarantine_trading_days == 1
    end
  end

  describe "auto_promote_eligible_discovery_versions/0" do
    test "promotes a discovery version with enough closed runs and non-negative pnl" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})

      for _ <- 1..20, do: closed_run_fixture(version, Decimal.new("1.00"))

      {:ok, [promoted]} = Sim.auto_promote_eligible_discovery_versions()

      assert promoted.id == version.id
      assert promoted.lifecycle_stage == "quarantine"
    end

    test "does not promote a version with too few closed runs" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})

      for _ <- 1..5, do: closed_run_fixture(version, Decimal.new("1.00"))

      {:ok, []} = Sim.auto_promote_eligible_discovery_versions()

      assert Sim.get_strategy_version!(version.id).lifecycle_stage == "discovery"
    end

    test "does not promote a version with negative total realized_pnl" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})

      for _ <- 1..20, do: closed_run_fixture(version, Decimal.new("-1.00"))

      {:ok, []} = Sim.auto_promote_eligible_discovery_versions()

      assert Sim.get_strategy_version!(version.id).lifecycle_stage == "discovery"
    end

    test "does not promote a version with no target_pool_id" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      for _ <- 1..20, do: closed_run_fixture(version, Decimal.new("1.00"))

      {:ok, []} = Sim.auto_promote_eligible_discovery_versions()

      assert Sim.get_strategy_version!(version.id).lifecycle_stage == "discovery"
    end
  end

  describe "auto_retire_failing_quarantine_versions/0" do
    test "retires a version past the trading-days floor with a bad loss ratio" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})
      {:ok, version} = Sim.promote_strategy_version(version, "quarantine")

      {:ok, version} =
        version
        |> Ecto.Changeset.change(quarantine_trading_days: 20)
        |> TradingOptionsSim.Repo.update()

      closed_run_fixture(version, Decimal.new("-100.00"))
      closed_run_fixture(version, Decimal.new("10.00"))

      {:ok, [retired]} = Sim.auto_retire_failing_quarantine_versions()

      assert retired.id == version.id
      assert retired.lifecycle_stage == "retired"
      assert retired.retired_reason == "failed_quarantine"
    end

    test "does not retire a version below the trading-days floor even with a bad loss ratio" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})
      {:ok, version} = Sim.promote_strategy_version(version, "quarantine")

      closed_run_fixture(version, Decimal.new("-100.00"))
      closed_run_fixture(version, Decimal.new("10.00"))

      {:ok, []} = Sim.auto_retire_failing_quarantine_versions()

      assert Sim.get_strategy_version!(version.id).lifecycle_stage == "quarantine"
    end

    test "does not retire a version past the floor with an acceptable loss ratio" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})
      {:ok, version} = Sim.promote_strategy_version(version, "quarantine")

      {:ok, version} =
        version
        |> Ecto.Changeset.change(quarantine_trading_days: 20)
        |> TradingOptionsSim.Repo.update()

      closed_run_fixture(version, Decimal.new("-10.00"))
      closed_run_fixture(version, Decimal.new("10.00"))

      {:ok, []} = Sim.auto_retire_failing_quarantine_versions()

      assert Sim.get_strategy_version!(version.id).lifecycle_stage == "quarantine"
    end

    test "does not retire a version past the floor with zero wins (undefined ratio)" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})
      {:ok, version} = Sim.promote_strategy_version(version, "quarantine")

      {:ok, version} =
        version
        |> Ecto.Changeset.change(quarantine_trading_days: 20)
        |> TradingOptionsSim.Repo.update()

      closed_run_fixture(version, Decimal.new("-10.00"))

      {:ok, []} = Sim.auto_retire_failing_quarantine_versions()

      assert Sim.get_strategy_version!(version.id).lifecycle_stage == "quarantine"
    end
  end

  describe "QuarantineEligibilityWorker" do
    test "perform/1 runs the full check without error" do
      assert :ok = perform_job(QuarantineEligibilityWorker, %{})
    end
  end
end
