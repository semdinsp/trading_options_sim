defmodule TradingOptionsSim.Sim.StrategyVersionParamsTest do
  use TradingOptionsSim.DataCase, async: true

  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.StrategyVersion

  @risk %{"method" => "percent_of_entry", "stop_loss_percent" => 15, "take_profit_percent" => 25}

  defp create(params) do
    {:ok, strategy} = Sim.create_strategy(%{name: "Params #{System.unique_integer([:positive])}"})

    Sim.create_strategy_version(strategy, %{
      version: 1,
      position_sizing: %{"method" => "fixed_qty", "qty" => 1},
      params: params
    })
  end

  # Must not fire on healthy input: every config in use today passes.
  test "accepts no stop config, percent_of_entry, round_numbers and both exit strategies" do
    for params <- [
          %{},
          %{"min_hold_seconds" => 300},
          %{"risk_controls" => @risk},
          %{"risk_controls" => Map.put(@risk, "round_numbers", true)},
          %{"exit_strategy" => %{"method" => "ratchet", "trigger_pct" => 10, "lock_pct" => 2}},
          %{
            "risk_controls" => @risk,
            "exit_strategy" => %{"method" => "trailing", "trail_pct" => 8}
          }
        ] do
      assert StrategyVersion.params_errors(params) == [], inspect(params)
      assert {:ok, _} = create(params)
    end
  end

  @vol %{
    "method" => "volatility_multiple",
    "sl_vol_mult" => 0.5,
    "tp_vol_mult" => 1.0,
    "stop_loss_percent" => 15,
    "take_profit_percent" => 25
  }

  test "accepts volatility_multiple with its multiples and fallback percents" do
    assert StrategyVersion.params_errors(%{"risk_controls" => @vol}) == []
    assert {:ok, _} = create(%{"risk_controls" => Map.put(@vol, "round_numbers", true)})
  end

  # Without the percents a missing premium vol would fall back to the
  # library's 5%/10% default.
  test "rejects volatility_multiple without its fallback percents or multiples" do
    assert {:error, changeset} =
             create(%{"risk_controls" => Map.delete(@vol, "stop_loss_percent")})

    assert [{msg, _}] = Keyword.get_values(changeset.errors, :params)
    assert msg =~ "stop_loss_percent"

    assert [_] =
             StrategyVersion.params_errors(%{"risk_controls" => Map.delete(@vol, "sl_vol_mult")})
  end

  # RiskControls falls back to its 5%/10% default for an unknown method,
  # so these would otherwise run with stops nobody configured.
  test "rejects an unknown method and a percent_of_entry missing its percents" do
    assert [_] = StrategyVersion.params_errors(%{"risk_controls" => %{"method" => "atr"}})
    assert [_] = StrategyVersion.params_errors(%{"risk_controls" => %{}})

    assert [msg] =
             StrategyVersion.params_errors(%{
               "risk_controls" => Map.delete(@risk, "take_profit_percent")
             })

    assert msg =~ "take_profit_percent"

    assert [_] =
             StrategyVersion.params_errors(%{
               "risk_controls" => Map.put(@risk, "round_numbers", "yes")
             })
  end

  test "rejects malformed exit strategies" do
    for bad <- [
          %{"method" => "ratchet", "trigger_pct" => 5},
          %{"method" => "ratchet", "trigger_pct" => 5, "lock_pct" => 6},
          %{"method" => "trailing"},
          %{"method" => "trailing", "trail_pct" => 0},
          %{"method" => "trailing", "trail_pct" => 100},
          %{"method" => "chandelier"},
          "trailing"
        ] do
      assert [_] = StrategyVersion.params_errors(%{"exit_strategy" => bad}), inspect(bad)
    end
  end
end
