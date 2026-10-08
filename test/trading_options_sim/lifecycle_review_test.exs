defmodule TradingOptionsSim.LifecycleReviewTest do
  # async: false: SimActivator starts real ContractMonitors for forks.
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.{LifecycleReview, Repo, Sim}

  defp version_fixture(name, attrs \\ %{}) do
    {:ok, pool} = Sim.create_target_pool(%{name: "#{name} Pool"})

    {:ok, _} =
      Sim.add_target_pool_member(pool, %{symbol: "LCR#{System.unique_integer([:positive])}"})

    {:ok, strategy} = Sim.create_strategy(%{name: name})

    {:ok, version} =
      Sim.create_strategy_version(
        strategy,
        Map.merge(
          %{
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
          },
          attrs
        )
      )

    {:ok, version} = Sim.mark_activated(version)
    version
  end

  # `count` closed trades of `net` each, regime cell {trend, vol}, spread
  # over `days` distinct exit dates (starting `offset` days ago).
  defp add_trades(version, count, net, {trend, vol}, days, offset \\ 1) do
    for i <- 0..(count - 1) do
      at = DateTime.utc_now() |> DateTime.add(-(offset + rem(i, days)) * 86_400, :second)

      {:ok, run} =
        Sim.open_sim_run(version, %{
          symbol: "LCR",
          expiry: "20271231",
          strike: Decimal.new("150.00"),
          right: "P",
          multiplier: 100,
          direction: "long"
        })

      {:ok, {_f, run}} =
        Sim.record_entry_fill(
          run,
          %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: at},
          %{
            entry_at: at,
            entry_price: Decimal.new("5.00"),
            entry_snapshot: %{"regime_trend_ordinal" => trend, "regime_vol_ordinal" => vol}
          }
        )

      {:ok, _} =
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
    end
  end

  defp action_for(actions, version), do: Enum.find(actions, &(&1.version_id == version.id))
  defp active?(version), do: is_nil(Sim.get_strategy_version!(version.id).deactivated_at)

  defp retired_by_review?(version) do
    v = Sim.get_strategy_version!(version.id)
    v.lifecycle_stage == "retired" and v.retired_reason == "lifecycle_review"
  end

  test "a loser with no profitable regime is retired (monitors stopped), not forked" do
    v = version_fixture("LCR Loser")
    add_trades(v, 30, "-5", {-1, -1}, 3)

    actions = LifecycleReview.run(mode: :apply)

    assert action_for(actions, v).action == :retire
    refute active?(v)
    assert retired_by_review?(v)
    refute Repo.exists?(from s in Sim.Strategy, where: like(s.name, "LCR Loser [Regime:%"))
  end

  test "a loser profitable in one regime is forked with that regime gate; the parent is retired" do
    v = version_fixture("LCR Rescue")
    add_trades(v, 15, "10", {-1, -1}, 2)
    add_trades(v, 30, "-10", {1, 0}, 3)

    actions = LifecycleReview.run(mode: :apply)
    a = action_for(actions, v)

    assert a.action == :fork_and_retire
    assert {a.cell.trend, a.cell.vol, a.cell.n} == {-1, -1, 15}
    refute active?(v)
    assert retired_by_review?(v)

    [fork] =
      Repo.all(
        from sv in Sim.StrategyVersion,
          join: s in assoc(sv, :strategy),
          where: s.name == "LCR Rescue [Regime: down/calm]",
          preload: :tags
      )

    assert fork.parent_version_id == v.id
    assert is_nil(fork.deactivated_at) and not is_nil(fork.activated_at)
    assert %{"all" => [orig, gate]} = fork.rules["entry"]
    assert orig == v.rules["entry"]
    assert gate == LifecycleReview.regime_gate(%{trend: -1, vol: -1})
    assert fork.params["risk_controls"]["stop_loss_percent"] == 10
    assert "Regime-Gated-Fork" in Enum.map(fork.tags, & &1.name)
  end

  test "dry run reports the same plan but changes nothing" do
    v = version_fixture("LCR Dry")
    add_trades(v, 15, "10", {-1, -1}, 2)
    add_trades(v, 30, "-10", {1, 0}, 3)

    actions = LifecycleReview.run(mode: :dry_run)

    assert %{action: :fork_and_retire, applied: false} = action_for(actions, v)
    assert active?(v)
    assert Sim.get_strategy_version!(v.id).lifecycle_stage == "discovery"
    refute Repo.exists?(from s in Sim.Strategy, where: like(s.name, "LCR Dry [Regime:%"))
  end

  test "a profitable regime on a single session is not enough to fork" do
    v = version_fixture("LCR OneDay")
    add_trades(v, 15, "10", {-1, -1}, 1)
    add_trades(v, 30, "-10", {1, 0}, 3, 2)

    assert action_for(LifecycleReview.run(mode: :dry_run), v).action == :retire
  end

  # Healthy input must not fire.
  test "profitable, young or protected versions are left alone" do
    winner = version_fixture("LCR Winner")
    add_trades(winner, 30, "5", {1, 0}, 3)

    young = version_fixture("LCR Young")
    add_trades(young, 29, "-5", {1, 0}, 3)

    control = version_fixture("LCR Control: Always-Long Put")
    add_trades(control, 30, "-5", {1, 0}, 3)

    linked = version_fixture("LCR Linked")
    add_trades(linked, 30, "-5", {1, 0}, 3)

    {:ok, _} =
      linked |> Ecto.Changeset.change(live_strategy_id: Ecto.UUID.generate()) |> Repo.update()

    baseline = version_fixture("LCR Baseline")
    add_trades(baseline, 30, "-5", {1, 0}, 3)
    {:ok, _} = Sim.add_tag_to_strategy_version_by_name(baseline, "Noise-Baseline")

    actions = LifecycleReview.run(mode: :apply)

    for v <- [winner, young, control, linked, baseline] do
      assert action_for(actions, v) == nil
      assert active?(v)
      refute Sim.get_strategy_version!(v.id).lifecycle_stage == "retired"
    end
  end

  test "a failing quarantine version with a profitable regime is forked, then retired by the review" do
    v = version_fixture("LCR Quarantine")
    {:ok, v} = Sim.promote_strategy_version(v, "quarantine")
    {:ok, v} = v |> Ecto.Changeset.change(quarantine_trading_days: 20) |> Repo.update()
    add_trades(v, 15, "10", {-1, -1}, 2)
    add_trades(v, 30, "-20", {1, 0}, 3)

    {:ok, retired} = Sim.auto_retire_failing_quarantine_versions()
    refute Enum.any?(retired, &(&1.id == v.id))

    assert action_for(LifecycleReview.run(mode: :apply), v).action == :fork_and_retire
    # Retired by the review (its regime edge lives on in the fork), not by
    # the quarantine job's failed_quarantine path, which skips it.
    assert retired_by_review?(v)
    refute active?(v)

    assert Repo.exists?(
             from s in Sim.Strategy, where: s.name == "LCR Quarantine [Regime: down/calm]"
           )
  end
end
