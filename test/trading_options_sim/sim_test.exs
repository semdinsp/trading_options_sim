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

  describe "update_trading_hours_settings/2" do
    test "defaults to regular_hours_only and overnight_hold false" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      assert version.trading_hours_policy == "regular_hours_only"
      assert version.overnight_hold == false
    end

    test "updates trading_hours_policy" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      assert {:ok, updated} =
               Sim.update_trading_hours_settings(version, %{
                 trading_hours_policy: "unrestricted"
               })

      assert updated.trading_hours_policy == "unrestricted"
    end

    test "rejects an invalid trading_hours_policy" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      assert {:error, changeset} =
               Sim.update_trading_hours_settings(version, %{trading_hours_policy: "bogus"})

      assert "is invalid" in errors_on(changeset).trading_hours_policy
    end

    test "updates overnight_hold independently" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      assert {:ok, updated} = Sim.update_trading_hours_settings(version, %{overnight_hold: true})
      assert updated.overnight_hold == true
      assert updated.trading_hours_policy == "regular_hours_only"
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

    test "remove_tag_from_strategy_version/2 removes only the given tag" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, version} = Sim.add_tag_to_strategy_version_by_name(version, "keep")
      {:ok, version} = Sim.add_tag_to_strategy_version_by_name(version, "remove me")
      tag_to_remove = Enum.find(version.tags, &(&1.name == "remove me"))

      {:ok, version} = Sim.remove_tag_from_strategy_version(version, tag_to_remove.id)

      assert Enum.map(version.tags, & &1.name) == ["keep"]
    end

    test "remove_tag_from_strategy_version/2 is a no-op if the tag isn't applied" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, version} = Sim.add_tag_to_strategy_version_by_name(version, "keep")

      {:ok, version} = Sim.remove_tag_from_strategy_version(version, Ecto.UUID.generate())

      assert Enum.map(version.tags, & &1.name) == ["keep"]
    end

    test "delete_tag/1 removes it from every strategy version and run it was applied to" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, version} = Sim.add_tag_to_strategy_version_by_name(version, "doomed")
      tag = hd(version.tags)

      assert {:ok, _} = Sim.delete_tag(tag)

      version = Sim.get_strategy_version!(version.id) |> TradingOptionsSim.Repo.preload(:tags)
      assert version.tags == []
      assert Sim.list_tags() == []
    end

    test "add_tag_to_run_by_name/2 is a no-op if already present" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      {:ok, run} =
        Sim.open_sim_run(version, %{
          symbol: "AAPL",
          expiry: "20271231",
          strike: Decimal.new("150.00"),
          right: "C",
          multiplier: 100,
          direction: "long"
        })

      {:ok, run} = Sim.add_tag_to_run_by_name(run, "needs review")
      {:ok, run} = Sim.add_tag_to_run_by_name(run, "needs review")

      assert length(run.tags) == 1
    end

    test "put_run_tags/2 replaces the full tag set" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      {:ok, run} =
        Sim.open_sim_run(version, %{
          symbol: "AAPL",
          expiry: "20271231",
          strike: Decimal.new("150.00"),
          right: "C",
          multiplier: 100,
          direction: "long"
        })

      {:ok, tag_a} = Sim.get_or_create_tag("a")
      {:ok, tag_b} = Sim.get_or_create_tag("b")

      {:ok, run} = Sim.put_run_tags(run, [tag_a.id, tag_b.id])
      assert length(run.tags) == 2

      {:ok, run} = Sim.put_run_tags(run, [])
      assert run.tags == []
    end
  end

  describe "list_strategy_versions/1" do
    test "returns every version across every strategy when stage is nil" do
      strategy = strategy_fixture()
      version_fixture(strategy, %{version: 1})
      version_fixture(strategy, %{version: 2})

      assert length(Sim.list_strategy_versions()) == 2
    end

    test "filters to one lifecycle_stage" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      discovery_version = version_fixture(strategy, %{version: 1})
      quarantine_version = version_fixture(strategy, %{version: 2, target_pool_id: pool.id})
      {:ok, quarantine_version} = Sim.promote_strategy_version(quarantine_version, "quarantine")

      discovery_ids = Sim.list_strategy_versions("discovery") |> Enum.map(& &1.id)
      quarantine_ids = Sim.list_strategy_versions("quarantine") |> Enum.map(& &1.id)

      assert discovery_version.id in discovery_ids
      refute quarantine_version.id in discovery_ids
      assert quarantine_version.id in quarantine_ids
    end

    test "preloads :strategy and :tags" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, _version} = Sim.add_tag_to_strategy_version_by_name(version, "reviewed")

      [loaded] = Sim.list_strategy_versions()
      assert loaded.strategy.id == strategy.id
      assert Enum.map(loaded.tags, & &1.name) == ["reviewed"]
    end
  end

  describe "strategy_version_stage_counts/0" do
    test "counts versions per lifecycle_stage across every strategy" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version_fixture(strategy, %{version: 1})
      version_fixture(strategy, %{version: 2})
      quarantine_version = version_fixture(strategy, %{version: 3, target_pool_id: pool.id})
      {:ok, _} = Sim.promote_strategy_version(quarantine_version, "quarantine")

      counts = Sim.strategy_version_stage_counts()

      assert counts["discovery"] == 2
      assert counts["quarantine"] == 1
      refute Map.has_key?(counts, "retired")
    end

    test "returns an empty map when no versions exist" do
      assert Sim.strategy_version_stage_counts() == %{}
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

  describe "list_recent_fills_for_version/2" do
    test "returns entry and exit fills across every member's contract, most recent first" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      close_run(run_fixture(version, "AAPL"))
      close_run(run_fixture(version, "MSFT"))

      fills = Sim.list_recent_fills_for_version(version)

      assert length(fills) == 4
      assert Enum.map(fills, & &1.kind) |> Enum.frequencies() == %{"entry" => 2, "exit" => 2}
    end

    test "preloads sim_run so symbol/contract fields are available" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      close_run(run_fixture(version, "AAPL"))

      [fill | _] = Sim.list_recent_fills_for_version(version)

      assert fill.sim_run.symbol == "AAPL"
    end

    test "ignores fills belonging to a different strategy version" do
      strategy = strategy_fixture()
      version_a = version_fixture(strategy, %{version: 1})
      version_b = version_fixture(strategy, %{version: 2})
      close_run(run_fixture(version_a, "AAPL"))
      close_run(run_fixture(version_b, "MSFT"))

      fills = Sim.list_recent_fills_for_version(version_a)

      assert Enum.all?(fills, &(&1.sim_run.symbol == "AAPL"))
    end

    test "respects the limit" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      close_run(run_fixture(version, "AAPL"))
      close_run(run_fixture(version, "MSFT"))

      assert length(Sim.list_recent_fills_for_version(version, 2)) == 2
    end

    test "returns an empty list when there are no fills yet" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      assert Sim.list_recent_fills_for_version(version) == []
    end
  end

  describe "last_closed_sim_run/2" do
    test "returns nil when no closed run exists for the symbol" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      run_fixture(version, "AAPL")

      assert Sim.last_closed_sim_run(version, "AAPL") == nil
    end

    test "returns the most recently closed run for that symbol" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      close_run(run_fixture(version, "AAPL"))
      newer = close_run(run_fixture(version, "AAPL"))

      assert Sim.last_closed_sim_run(version, "AAPL").id == newer.id
    end

    test "ignores closed runs for a different symbol" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      close_run(run_fixture(version, "MSFT"))

      assert Sim.last_closed_sim_run(version, "AAPL") == nil
    end
  end

  describe "list_active_strategy_versions/0" do
    test "returns only versions with activated_at set and deactivated_at nil" do
      strategy = strategy_fixture()
      activated_version = version_fixture(strategy, %{version: 1})
      never_activated_version = version_fixture(strategy, %{version: 2})
      deactivated_version = version_fixture(strategy, %{version: 3})

      {:ok, activated_version} = Sim.mark_activated(activated_version)
      {:ok, deactivated_version} = Sim.mark_activated(deactivated_version)
      {:ok, deactivated_version} = Sim.mark_deactivated(deactivated_version)

      active_ids = Sim.list_active_strategy_versions() |> Enum.map(& &1.id)

      assert activated_version.id in active_ids
      refute never_activated_version.id in active_ids
      refute deactivated_version.id in active_ids
    end

    # downgrade_strategy_version/3 only flips lifecycle_stage — it does
    # not itself deactivate — so a version retired without first being
    # deactivated would otherwise still look "active" here.
    test "excludes a retired version even if never explicitly deactivated" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, version} = Sim.mark_activated(version)
      {:ok, retired} = Sim.downgrade_strategy_version(version, "retired")

      refute is_nil(retired.activated_at)
      assert is_nil(retired.deactivated_at)
      refute retired.id in Enum.map(Sim.list_active_strategy_versions(), & &1.id)
    end

    # A version stays "active" while flat — it's the activated_at/
    # deactivated_at pair that decides membership, not whether it
    # happens to have an open run right now (see those fields' own doc
    # on why: this is exactly the distinction that was missing before
    # 2026-09-15, when a flat-but-active version's monitor was silently
    # lost on every app restart).
    test "includes an activated version with zero open runs (flat, not deactivated)" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, version} = Sim.mark_activated(version)
      close_run(run_fixture(version, "AAPL"))

      [active] = Sim.list_active_strategy_versions()

      assert active.id == version.id
      assert active.sim_runs == []
    end

    test "preloads :strategy and only the open sim_runs" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, version} = Sim.mark_activated(version)
      run_fixture(version, "AAPL")
      close_run(run_fixture(version, "MSFT"))

      [active] = Sim.list_active_strategy_versions()

      assert active.strategy.id == strategy.id
      assert Enum.map(active.sim_runs, & &1.symbol) == ["AAPL"]
    end
  end

  describe "mark_activated/1 and mark_deactivated/1" do
    test "mark_activated/1 sets activated_at and clears deactivated_at" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, version} = Sim.mark_activated(version)
      {:ok, version} = Sim.mark_deactivated(version)

      {:ok, reactivated} = Sim.mark_activated(version)

      refute is_nil(reactivated.activated_at)
      assert is_nil(reactivated.deactivated_at)
    end

    test "mark_deactivated/1 sets deactivated_at, leaves activated_at as history" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, version} = Sim.mark_activated(version)

      {:ok, deactivated} = Sim.mark_deactivated(version)

      refute is_nil(deactivated.activated_at)
      refute is_nil(deactivated.deactivated_at)
    end
  end

  describe "get_close_before_minutes/1" do
    test "returns the mapped session's close_before_minutes" do
      exchange = "TEST_EX_#{System.unique_integer([:positive])}"

      {:ok, hours} =
        %TradingOptionsSim.Sim.ExchangeTradingHours{}
        |> TradingOptionsSim.Sim.ExchangeTradingHours.changeset(%{
          name: exchange,
          timezone: "Etc/UTC",
          start_time: ~T[00:00:00],
          end_time: ~T[23:59:59],
          days_of_week: [1, 2, 3, 4, 5],
          close_before_minutes: 15
        })
        |> Repo.insert()

      {:ok, _session} =
        %TradingOptionsSim.Sim.ExchangeSession{}
        |> TradingOptionsSim.Sim.ExchangeSession.changeset(%{
          exchange: exchange,
          exchange_trading_hours_id: hours.id
        })
        |> Repo.insert()

      assert Sim.get_close_before_minutes(exchange) == 15
    end

    test "returns nil for an unmapped exchange" do
      assert Sim.get_close_before_minutes("NEVER_MAPPED") == nil
    end
  end

  describe "list_strategy_versions_page/2" do
    test "paginates and returns total_count across the whole filtered set" do
      strategy = strategy_fixture()
      for v <- 1..5, do: version_fixture(strategy, %{version: v})

      {page1, total} = Sim.list_strategy_versions_page(nil, limit: 2, offset: 0)
      assert total == 5
      assert length(page1) == 2

      {page2, total} = Sim.list_strategy_versions_page(nil, limit: 2, offset: 2)
      assert total == 5
      assert length(page2) == 2

      assert Enum.map(page1, & &1.id) != Enum.map(page2, & &1.id)
    end

    test "filters by lifecycle_stage" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      discovery_version = version_fixture(strategy, %{version: 1})
      quarantined = version_fixture(strategy, %{version: 2, target_pool_id: pool.id})
      {:ok, _quarantined} = Sim.promote_strategy_version(quarantined, "quarantine")

      {versions, total} = Sim.list_strategy_versions_page("discovery", limit: 20, offset: 0)
      assert total == 1
      assert [%{id: id}] = versions
      assert id == discovery_version.id
    end

    test "clamps limit to the max page size" do
      strategy = strategy_fixture()
      for v <- 1..3, do: version_fixture(strategy, %{version: v})

      {versions, _total} = Sim.list_strategy_versions_page(nil, limit: 10_000, offset: 0)
      assert length(versions) == 3
    end

    test "preloads :strategy and :tags" do
      strategy = strategy_fixture()
      version_fixture(strategy, %{version: 1})

      {[version], _total} = Sim.list_strategy_versions_page(nil, limit: 20, offset: 0)
      assert %TradingOptionsSim.Sim.Strategy{} = version.strategy
      assert version.tags == []
    end
  end

  describe "list_sim_runs_page/2" do
    defp page_run_fixture(version, attrs \\ %{}) do
      {:ok, run} =
        Sim.open_sim_run(
          version,
          Map.merge(
            %{
              symbol: "AAPL",
              expiry: "20270115",
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

    test "paginates and returns total_count" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      for _ <- 1..5, do: page_run_fixture(version)

      {page1, total} = Sim.list_sim_runs_page(nil, limit: 2, offset: 0)
      assert total == 5
      assert length(page1) == 2
    end

    test "filters by status" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      open_run = page_run_fixture(version)
      closed_run = page_run_fixture(version)

      now = DateTime.utc_now()

      {:ok, {_fill, closed_run}} =
        Sim.record_entry_fill(
          closed_run,
          %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: now},
          %{entry_at: now, entry_price: Decimal.new("5.00")}
        )

      {:ok, {_fill, _closed_run}} =
        Sim.record_exit_fill(
          closed_run,
          %{action: "sell", quantity: 1, fill_price: Decimal.new("4.00"), filled_at: now},
          %{
            exit_at: now,
            exit_price: Decimal.new("4.00"),
            exit_reason: "stopped_out",
            realized_pnl: Decimal.new("-100.00")
          }
        )

      {open_runs, open_total} = Sim.list_sim_runs_page("open", limit: 20, offset: 0)
      assert open_total == 1
      assert [%{id: id}] = open_runs
      assert id == open_run.id

      {closed_runs, closed_total} = Sim.list_sim_runs_page("closed", limit: 20, offset: 0)
      assert closed_total == 1
      assert [%{id: id}] = closed_runs
      assert id == closed_run.id
    end

    test "preloads :tags and strategy_version: :strategy" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      page_run_fixture(version)

      {[run], _total} = Sim.list_sim_runs_page(nil, limit: 20, offset: 0)
      assert run.tags == []
      assert %TradingOptionsSim.Sim.StrategyVersion{} = run.strategy_version
      assert %TradingOptionsSim.Sim.Strategy{} = run.strategy_version.strategy
    end
  end

  describe "snapshot_version/2" do
    defp closed_run_fixture(version, attrs) do
      {:ok, run} =
        Sim.open_sim_run(
          version,
          Map.merge(
            %{
              symbol: "SNAP1",
              expiry: "20271231",
              strike: Decimal.new("150.00"),
              right: "C",
              multiplier: 100,
              direction: "long"
            },
            attrs
          )
        )

      now = DateTime.utc_now()

      {:ok, {_fill, run}} =
        Sim.record_entry_fill(
          run,
          %{
            action: "buy",
            quantity: 1,
            fill_price: Decimal.new("5.00"),
            filled_at: now,
            commission: Decimal.new("1.68")
          },
          %{entry_at: now, entry_price: Decimal.new("5.00")}
        )

      {:ok, {_fill, run}} =
        Sim.record_exit_fill(
          run,
          %{
            action: "sell",
            quantity: 1,
            fill_price: Decimal.new("6.00"),
            filled_at: now,
            commission: Decimal.new("1.68")
          },
          %{
            exit_at: now,
            exit_price: Decimal.new("6.00"),
            exit_reason: "target_hit",
            realized_pnl: Decimal.new("100.00"),
            realized_pnl_net: Decimal.new("96.64")
          }
        )

      run
    end

    test "is a no-op when the version has no closed runs" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)

      assert Sim.snapshot_version(version) == :ok
      assert Sim.list_performance_snapshots(version) == []
    end

    test "computes n_trades/win_rate/gross+net pnl/commission from closed runs" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, version} = Sim.mark_activated(version)

      closed_run_fixture(version, %{symbol: "SNAP2"})

      assert {:ok, snapshot} = Sim.snapshot_version(version)
      assert snapshot.n_trades == 1
      assert snapshot.n_wins == 1
      assert snapshot.n_losses == 0
      assert Decimal.equal?(snapshot.win_rate, Decimal.new(1))
      assert Decimal.equal?(snapshot.realized_pnl_gross, Decimal.new("100.00"))
      assert Decimal.equal?(snapshot.realized_pnl_net, Decimal.new("96.64"))
      assert Decimal.equal?(snapshot.total_commission, Decimal.new("3.36"))
      assert snapshot.lifecycle_stage == "discovery"
    end

    test "period_start is the version's activated_at when set" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      {:ok, version} = Sim.mark_activated(version)
      closed_run_fixture(version, %{symbol: "SNAP3"})

      assert {:ok, snapshot} = Sim.snapshot_version(version)
      assert DateTime.compare(snapshot.period_start, version.activated_at) == :eq
    end

    test "period_start falls back to inserted_at when never activated" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      closed_run_fixture(version, %{symbol: "SNAP4"})

      assert {:ok, snapshot} = Sim.snapshot_version(version)
      assert DateTime.compare(snapshot.period_start, version.inserted_at) == :eq
    end
  end

  describe "snapshot_all_active_versions/0" do
    test "snapshots discovery/quarantine/test_portfolio versions with closed runs, skips the rest" do
      strategy = strategy_fixture()

      traded_version = version_fixture(strategy, %{version: 1})
      closed_run_fixture(traded_version, %{symbol: "SNAPALL1"})

      untraded_version = version_fixture(strategy, %{version: 2})

      pool = target_pool_fixture()
      retired_version = version_fixture(strategy, %{version: 3, target_pool_id: pool.id})
      {:ok, retired_version} = Sim.downgrade_strategy_version(retired_version, "retired")
      closed_run_fixture(retired_version, %{symbol: "SNAPALL3"})

      counts = Sim.snapshot_all_active_versions()

      assert counts.snapshotted == 1
      assert counts.skipped == 1

      assert [_snapshot] = Sim.list_performance_snapshots(traded_version)
      assert Sim.list_performance_snapshots(untraded_version) == []
      assert Sim.list_performance_snapshots(retired_version) == []
    end
  end

  describe "list_performance_snapshots/1" do
    test "returns snapshots most-recent-first" do
      strategy = strategy_fixture()
      version = version_fixture(strategy)
      closed_run_fixture(version, %{symbol: "SNAPLIST1"})

      {:ok, _first} = Sim.snapshot_version(version, ~U[2026-09-14 21:00:00Z])
      {:ok, _second} = Sim.snapshot_version(version, ~U[2026-09-15 21:00:00Z])

      [most_recent, oldest] = Sim.list_performance_snapshots(version)
      assert DateTime.compare(most_recent.period_end, oldest.period_end) == :gt
    end
  end

  describe "full_universe_version_metrics/0" do
    defp candidate_run_fixture(version, attrs) do
      {:ok, run} =
        Sim.open_sim_run(
          version,
          Map.merge(
            %{
              symbol: "CAND1",
              expiry: "20271231",
              strike: Decimal.new("150.00"),
              right: "C",
              multiplier: 100,
              direction: "long"
            },
            Map.take(attrs, [:symbol])
          )
        )

      now = DateTime.utc_now()
      entry_price = Decimal.new("5.00")
      risk_at_entry = Sim.compute_risk_at_entry(entry_price, 100, 1)

      {:ok, {_fill, run}} =
        Sim.record_entry_fill(
          run,
          %{
            action: "buy",
            quantity: 1,
            fill_price: entry_price,
            filled_at: now,
            commission: Decimal.new("1.68")
          },
          %{entry_at: now, entry_price: entry_price, risk_at_entry: risk_at_entry}
        )

      {:ok, {_fill, run}} =
        Sim.record_exit_fill(
          run,
          %{
            action: "sell",
            quantity: 1,
            fill_price: Map.fetch!(attrs, :exit_price),
            filled_at: now,
            commission: Decimal.new("1.68")
          },
          %{
            exit_at: now,
            exit_price: Map.fetch!(attrs, :exit_price),
            exit_reason: Map.get(attrs, :exit_reason, "target_hit"),
            realized_pnl: Map.fetch!(attrs, :realized_pnl),
            realized_pnl_net: Map.fetch!(attrs, :realized_pnl)
          }
        )

      run
    end

    test "computes n_closes/expectancy_r/realized_pnl for a discovery version" do
      strategy = strategy_fixture()
      version = version_fixture(strategy, %{version: 1})

      for _ <- 1..2 do
        candidate_run_fixture(version, %{
          symbol: "CAND2",
          exit_price: Decimal.new("6.00"),
          realized_pnl: Decimal.new("100.00")
        })
      end

      [row] =
        Sim.full_universe_version_metrics()
        |> Enum.filter(&(&1.strategy_version_id == version.id))

      assert row.n_closes == 2
      assert row.lifecycle_stage == "discovery"
      refute is_nil(row.expectancy_r)
      assert Decimal.equal?(row.realized_pnl, Decimal.new("200.00"))
    end

    test "excludes churned runs from expectancy_r/realized_pnl but counts them as excluded" do
      strategy = strategy_fixture()
      version = version_fixture(strategy, %{version: 1})

      run =
        candidate_run_fixture(version, %{
          symbol: "CAND3",
          exit_price: Decimal.new("6.00"),
          realized_pnl: Decimal.new("100.00")
        })

      {:ok, _run} = run |> TradingOptionsSim.Sim.SimRun.churn_changeset() |> Repo.update()

      [row] =
        Sim.full_universe_version_metrics()
        |> Enum.filter(&(&1.strategy_version_id == version.id))

      assert row.n_closes == 0
      assert row.excluded_count == 1
      assert Decimal.equal?(row.excluded_pnl, Decimal.new("100.00"))
    end

    test "only returns discovery/quarantine versions, not retired ones" do
      strategy = strategy_fixture()
      pool = target_pool_fixture()
      version = version_fixture(strategy, %{version: 1, target_pool_id: pool.id})
      {:ok, version} = Sim.downgrade_strategy_version(version, "retired")

      refute Sim.full_universe_version_metrics()
             |> Enum.any?(&(&1.strategy_version_id == version.id))
    end

    test "builds an exit_reason_histogram across closed runs" do
      strategy = strategy_fixture()
      version = version_fixture(strategy, %{version: 1})

      candidate_run_fixture(version, %{
        symbol: "CAND4",
        exit_price: Decimal.new("6.00"),
        realized_pnl: Decimal.new("100.00"),
        exit_reason: "rule_exit"
      })

      candidate_run_fixture(version, %{
        symbol: "CAND4",
        exit_price: Decimal.new("4.00"),
        realized_pnl: Decimal.new("-100.00"),
        exit_reason: "expiry"
      })

      [row] =
        Sim.full_universe_version_metrics()
        |> Enum.filter(&(&1.strategy_version_id == version.id))

      assert row.exit_reason_histogram == %{"rule_exit" => 1, "expiry" => 1}
    end
  end
end
