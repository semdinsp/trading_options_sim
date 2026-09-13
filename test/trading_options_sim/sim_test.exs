defmodule TradingOptionsSim.SimTest do
  use TradingOptionsSim.DataCase, async: true

  alias TradingOptionsSim.Sim

  defp strategy_fixture(attrs \\ %{}) do
    {:ok, strategy} = Sim.create_strategy(Map.merge(%{name: "Test Strategy"}, attrs))
    strategy
  end

  defp target_pool_fixture(attrs \\ %{}) do
    {:ok, pool} = Sim.create_target_pool(Map.merge(%{name: "Mega Cap Tech"}, attrs))
    pool
  end

  defp version_fixture(strategy, attrs \\ %{}) do
    {:ok, version} =
      Sim.create_strategy_version(
        strategy,
        Map.merge(%{version: 1, position_sizing: %{"method" => "fixed_qty", "qty" => 1}}, attrs)
      )

    version
  end

  describe "create_strategy_version/2" do
    test "defaults lifecycle_stage to discovery" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      assert version.lifecycle_stage == "discovery"
    end

    test "requires position_sizing" do
      strategy = strategy_fixture()

      assert {:error, changeset} = Sim.create_strategy_version(strategy, %{version: 1})
      assert "can't be blank" in errors_on(changeset).position_sizing
    end
  end

  describe "promote_strategy_version/2 — discovery -> quarantine" do
    test "requires a target_pool_id" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      assert {:error, :no_target_pool} = Sim.promote_strategy_version(version, "quarantine")
    end

    test "succeeds with a target pool, sets quarantine_started_at and resets trading_days" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})

      assert {:ok, promoted} = Sim.promote_strategy_version(version, "quarantine")
      assert promoted.lifecycle_stage == "quarantine"
      assert promoted.quarantine_trading_days == 0
      refute is_nil(promoted.quarantine_started_at)
    end
  end

  describe "promote_strategy_version/2 — quarantine -> test_portfolio" do
    test "succeeds from quarantine" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})
      {:ok, version} = Sim.promote_strategy_version(version, "quarantine")

      assert {:ok, promoted} = Sim.promote_strategy_version(version, "test_portfolio")
      assert promoted.lifecycle_stage == "test_portfolio"
    end

    test "fails from discovery" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      assert {:error, :invalid_transition} =
               Sim.promote_strategy_version(version, "test_portfolio")
    end
  end

  describe "promote_strategy_version/2 — unretire" do
    test "retired -> discovery succeeds" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, retired} = Sim.downgrade_strategy_version(version, "retired")

      assert {:ok, unretired} = Sim.promote_strategy_version(retired, "discovery")
      assert unretired.lifecycle_stage == "discovery"
    end

    test "discovery -> discovery is an invalid transition" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      assert {:error, :invalid_transition} = Sim.promote_strategy_version(version, "discovery")
    end
  end

  describe "downgrade_strategy_version/3" do
    test "discovery -> retired succeeds with default reason" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      assert {:ok, retired} = Sim.downgrade_strategy_version(version, "retired")
      assert retired.lifecycle_stage == "retired"
      assert retired.retired_reason == "manual"
    end

    test "quarantine -> retired succeeds" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})
      {:ok, version} = Sim.promote_strategy_version(version, "quarantine")

      assert {:ok, retired} =
               Sim.downgrade_strategy_version(version, "retired", "failed_quarantine")

      assert retired.lifecycle_stage == "retired"
      assert retired.retired_reason == "failed_quarantine"
    end

    test "test_portfolio -> quarantine succeeds (the only way back to a live-eligible stage)" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})
      {:ok, version} = Sim.promote_strategy_version(version, "quarantine")
      {:ok, version} = Sim.promote_strategy_version(version, "test_portfolio")

      assert {:ok, downgraded} = Sim.downgrade_strategy_version(version, "quarantine")
      assert downgraded.lifecycle_stage == "quarantine"
    end

    test "retired -> quarantine is an invalid transition" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, retired} = Sim.downgrade_strategy_version(version, "retired")

      assert {:error, :invalid_transition} = Sim.downgrade_strategy_version(retired, "quarantine")
    end
  end

  describe "link_live_strategy/3" do
    test "succeeds from test_portfolio, keeps lifecycle_stage unchanged" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})
      {:ok, version} = Sim.promote_strategy_version(version, "quarantine")
      {:ok, version} = Sim.promote_strategy_version(version, "test_portfolio")

      live_strategy_id = Ecto.UUID.generate()

      assert {:ok, linked} =
               Sim.link_live_strategy(version, "trading_live", live_strategy_id)

      assert linked.lifecycle_stage == "test_portfolio"
      assert linked.live_strategy_app == "trading_live"
      assert linked.live_strategy_id == live_strategy_id
      assert linked.live_strategy_active == true
      refute is_nil(linked.live_linked_at)
    end

    test "fails from discovery" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      assert {:error, :invalid_transition} =
               Sim.link_live_strategy(version, "trading_live", "id")
    end
  end

  describe "unlink_live_strategy/1" do
    test "succeeds when currently linked" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{target_pool_id: pool.id})
      {:ok, version} = Sim.promote_strategy_version(version, "quarantine")
      {:ok, version} = Sim.promote_strategy_version(version, "test_portfolio")
      {:ok, version} = Sim.link_live_strategy(version, "trading_live", Ecto.UUID.generate())

      assert {:ok, unlinked} = Sim.unlink_live_strategy(version)
      assert unlinked.live_strategy_active == false
      refute is_nil(unlinked.live_unlinked_at)
      # History is preserved, not erased:
      assert unlinked.live_strategy_app == "trading_live"
      refute is_nil(unlinked.live_linked_at)
    end

    test "fails when not currently linked" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      assert {:error, :not_linked} = Sim.unlink_live_strategy(version)
    end
  end

  describe "tags" do
    test "get_or_create_tag/1 upserts by exact name match" do
      assert {:ok, tag1} = Sim.get_or_create_tag("no exit")
      assert {:ok, tag2} = Sim.get_or_create_tag("no exit")
      assert tag1.id == tag2.id
    end

    test "add_tag_to_strategy_version_by_name/2 is a no-op if already present" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      {:ok, version} = Sim.add_tag_to_strategy_version_by_name(version, "needs review")
      {:ok, version} = Sim.add_tag_to_strategy_version_by_name(version, "needs review")

      assert length(version.tags) == 1
    end

    test "put_strategy_version_tags/2 replaces the full tag set" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, tag_a} = Sim.get_or_create_tag("a")
      {:ok, tag_b} = Sim.get_or_create_tag("b")

      {:ok, version} = Sim.put_strategy_version_tags(version, [tag_a.id, tag_b.id])
      assert length(version.tags) == 2

      {:ok, version} = Sim.put_strategy_version_tags(version, [])
      assert version.tags == []
    end
  end

  describe "list_sim_runs/1" do
    defp run_fixture(version, symbol, attrs \\ %{}) do
      {:ok, run} =
        Sim.open_sim_run(
          version,
          Map.merge(
            %{
              symbol: symbol,
              expiry: "20271231",
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

    defp close_run(run) do
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
          %{action: "sell", quantity: 1, fill_price: Decimal.new("6.00"), filled_at: now},
          %{
            exit_at: now,
            exit_price: Decimal.new("6.00"),
            exit_reason: "rule_exit",
            realized_pnl: Decimal.new("1.00")
          }
        )

      run
    end

    test "returns every run across every version when status is nil" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      run_fixture(version, "AAPL")
      close_run(run_fixture(version, "MSFT"))

      symbols = Sim.list_sim_runs() |> Enum.map(& &1.symbol)
      assert Enum.sort(symbols) == ["AAPL", "MSFT"]
    end

    test "filters to only open runs" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      run_fixture(version, "AAPL")
      close_run(run_fixture(version, "MSFT"))

      assert Sim.list_sim_runs("open") |> Enum.map(& &1.symbol) == ["AAPL"]
    end

    test "filters to only closed runs" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      run_fixture(version, "AAPL")
      close_run(run_fixture(version, "MSFT"))

      assert Sim.list_sim_runs("closed") |> Enum.map(& &1.symbol) == ["MSFT"]
    end

    test "preloads strategy_version and its strategy" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      run_fixture(version, "AAPL")

      [run] = Sim.list_sim_runs()
      assert run.strategy_version.id == version.id
      assert run.strategy_version.strategy.id == strategy.id
    end
  end

  describe "list_active_strategy_versions/0" do
    test "returns only versions with at least one open run" do
      strategy = strategy_fixture()
      version_with_open_run = version_fixture(strategy, %{version: 1})
      version_with_no_runs = version_fixture(strategy, %{version: 2})
      version_all_closed = version_fixture(strategy, %{version: 3})

      run_fixture(version_with_open_run, "AAPL")
      close_run(run_fixture(version_all_closed, "MSFT"))

      active_ids = Sim.list_active_strategy_versions() |> Enum.map(& &1.id)

      assert version_with_open_run.id in active_ids
      refute version_with_no_runs.id in active_ids
      refute version_all_closed.id in active_ids
    end

    test "preloads :strategy and only the open sim_runs" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      run_fixture(version, "AAPL")
      close_run(run_fixture(version, "MSFT"))

      [active] = Sim.list_active_strategy_versions()

      assert active.strategy.id == strategy.id
      assert Enum.map(active.sim_runs, & &1.symbol) == ["AAPL"]
    end
  end
end
