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
end
