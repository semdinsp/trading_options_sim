defmodule TradingOptionsSim.VersionForkTest do
  # async: false -- the activate test starts real ContractMonitors.
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.{ContractMonitor, Repo, Sim, SimActivator, VersionFork}
  alias TradingOptionsSim.SignalBus.Test, as: SignalBusTest
  alias TradingOptionsSim.Sim.{Strategy, StrategyVersion}

  @risk %{"method" => "percent_of_entry", "stop_loss_percent" => 10, "take_profit_percent" => 20}
  @source_entry %{
    "all" => [
      %{
        "signal" => "definition:54a16234-cf29-44dd-9837-9c9036e11fab",
        "op" => "gt",
        "value" => 1.5
      },
      %{"signal" => "run_poly_vwap_dev_bps", "op" => "gt", "value" => 0}
    ]
  }
  @source_exit %{"signal" => "run_poly_vwap_dev_bps", "op" => "lt", "value" => 0}
  @leg %{
    "expiry_selection" => "fixed",
    "fixed_expiry" => "20271231",
    "strike_selection" => "fixed_strike",
    "fixed_strike" => "150.00",
    "right" => "P"
  }

  setup do
    {:ok, pool} =
      Sim.create_target_pool(%{name: "Fork pool #{System.unique_integer([:positive])}"})

    {:ok, _} = Sim.add_target_pool_member(pool, %{symbol: "FORKA"})
    {:ok, _} = Sim.add_target_pool_member(pool, %{symbol: "FORKB"})

    {:ok, strategy} = Sim.create_strategy(%{name: "Fork Source #{System.unique_integer()}"})

    {:ok, source} =
      Sim.create_strategy_version(strategy, %{
        version: 3,
        generation: 2,
        direction: "long",
        rules: %{"entry" => @source_entry, "exit" => @source_exit},
        option_leg_config: @leg,
        position_sizing: %{"method" => "fixed_qty", "qty" => 2},
        params: %{
          "min_hold_seconds" => 1200,
          "risk_controls" => @risk,
          "exit_strategy" => %{"method" => "trailing", "trail_pct" => 8}
        },
        usage_conditions: %{"note" => "kept"},
        target_pool_id: pool.id
      })

    {:ok, source} =
      Sim.update_trading_hours_settings(source, %{
        overnight_hold: true,
        trading_hours_policy: "unrestricted"
      })

    %{source: Repo.reload!(source), pool: pool}
  end

  defp gate, do: %{"signal" => "regime_vol_ordinal", "op" => "lt", "value" => -0.5}

  test "a fork copies params, leg config, pool, sizing, overnight_hold and trading_hours_policy exactly",
       %{source: source} do
    assert {:ok, %{version: fork, activation: nil}} =
             VersionFork.fork(source.id, name: "Fork Source [Copy]", tags: ["fork-test"])

    assert fork.id != source.id
    assert fork.strategy_id != source.strategy_id
    assert fork.strategy.name == "Fork Source [Copy]"
    assert fork.version == 1
    assert fork.lifecycle_stage == "discovery"
    assert fork.activated_at == nil
    assert fork.parent_version_id == source.id
    assert fork.generation == 3

    for field <- [
          :params,
          :rules,
          :option_leg_config,
          :position_sizing,
          :usage_conditions,
          :direction,
          :target_pool_id,
          :overnight_hold,
          :trading_hours_policy
        ] do
      assert Map.fetch!(fork, field) == Map.fetch!(source, field), "#{field} not copied"
    end

    assert fork.params["risk_controls"] == @risk
    assert fork.notes =~ "Forked from #{source.id}"
    assert Enum.map(fork.tags, & &1.name) == ["fork-test"]
  end

  test "entry_gate is AND-ed onto the source entry and the exit is untouched", %{source: source} do
    {:ok, %{version: fork}} =
      VersionFork.fork(source.id, name: "Fork Source [Gate]", entry_gate: gate(), notes: "why")

    assert fork.rules["entry"] == %{"all" => [@source_entry, gate()]}
    assert fork.rules["exit"] == @source_exit
    assert fork.notes =~ ~r/\Awhy\n\nForked from #{source.id}/
  end

  test "rules replaces both sides", %{source: source} do
    rules = %{
      "entry" => gate(),
      "exit" => %{"signal" => "run_delta", "op" => "lt", "value" => 0.2}
    }

    {:ok, %{version: fork}} =
      VersionFork.fork(source.id, name: "Fork Source [Rules]", rules: rules)

    assert fork.rules == rules
  end

  test "entry_gate with rules is rejected and nothing is written; the source is unchanged",
       %{source: source} do
    before = Repo.aggregate(Strategy, :count)

    assert {:error, :entry_gate_and_rules} =
             VersionFork.fork(source.id,
               name: "Fork Source [Both]",
               entry_gate: gate(),
               rules: %{"entry" => gate()}
             )

    assert Repo.aggregate(Strategy, :count) == before
    assert Repo.reload!(source) == source
  end

  test "rejects unknown signal names and invalid rules, writing nothing", %{source: source} do
    before = Repo.aggregate(StrategyVersion, :count)
    unknown = "no_such_signal_#{System.unique_integer([:positive])}"
    SignalBusTest.stub_unknown(unknown)

    assert {:error, {:unknown_signals, [^unknown]}} =
             VersionFork.fork(source.id,
               name: "Fork Source [Unknown]",
               entry_gate: %{"signal" => unknown, "op" => "gt", "value" => 0}
             )

    assert {:error, {:invalid_rules, [msg]}} =
             VersionFork.fork(source.id,
               name: "Fork Source [Bad op]",
               entry_gate: %{"signal" => "run_delta", "op" => "neq", "value" => 0}
             )

    assert msg =~ "unknown op"
    assert Repo.aggregate(StrategyVersion, :count) == before
  end

  test "local monitor keys never ask trading_signal", %{source: source} do
    assert {:ok, []} =
             VersionFork.unknown_signal_names(%{"entry" => gate(), "exit" => @source_exit})

    {:ok, _} = VersionFork.fork(source.id, name: "Fork Source [Local]", entry_gate: gate())
  end

  test "requires a name and an existing source", %{source: source} do
    assert {:error, :name_required} = VersionFork.fork(source.id, name: "  ")
    assert {:error, :not_found} = VersionFork.fork(Ecto.UUID.generate(), name: "x")
    assert {:error, :not_found} = VersionFork.fork("not-a-uuid", name: "x")
  end

  test "activate: true starts the monitors, same path as activate_version", %{source: source} do
    {:ok, %{version: fork, activation: activation}} =
      VersionFork.fork(source.id, name: "Fork Source [Active]", activate: true)

    assert activation == %{monitors: 2, unsubscribed_symbols: []}
    assert fork.id in Sim.active_strategy_version_ids()

    for symbol <- ["FORKA", "FORKB"] do
      assert ContractMonitor.whereis(fork.id, {symbol, "20271231", Decimal.new("150.00"), "P"})
    end

    assert {:ok, 2} = SimActivator.deactivate(Sim.get_strategy_version!(fork.id))
  end
end
