defmodule TradingOptionsSim.StopLadderMonitorTest do
  # The stop ladder on a live ContractMonitor: rows are written, rungs
  # keep recording after the real run stops out, and the run gets its
  # shadow exit. async: false: real monitors and a global ATR stub.
  use TradingOptionsSim.DataCase, async: false

  import Ecto.Query

  alias TradingOptionsSim.{ContractMonitor, Repo, Sim}
  alias TradingOptionsSim.Sim.SimRunStopLadder

  defmodule StubAtr do
    def lookup(_symbol, _period), do: {:ok, %{atr: Decimal.new("8.0")}}
  end

  setup do
    Application.put_env(:trading_options_sim, :daily_atr_source, StubAtr)
    on_exit(fn -> Application.delete_env(:trading_options_sim, :daily_atr_source) end)
  end

  # Enter above 149, exit below 140; SL10 / TP50; a 1 h cooldown so the
  # monitor doesn't re-enter after the stop.
  defp version_fixture do
    {:ok, strategy} = Sim.create_strategy(%{name: "Stop Ladder Monitor"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1},
        rules: %{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 149},
          "exit" => %{"signal" => "run_underlying_price", "op" => "lt", "value" => 140}
        },
        params: %{
          "reentry_cooldown_seconds" => 3600,
          "risk_controls" => %{
            "method" => "percent_of_entry",
            "stop_loss_percent" => 10,
            "take_profit_percent" => 50
          }
        }
      })

    version
  end

  defp start_monitor(version, symbol) do
    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: symbol,
        expiry: "20271231",
        strike: Decimal.new("150.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

    {:ok, pid} =
      start_supervised(
        {ContractMonitor,
         sim_run_id: run.id,
         contract_key: {symbol, "20271231", Decimal.new("150.00"), "C"},
         strategy_version: version,
         direction: "long",
         quantity: 1,
         exchange: nil}
      )

    {pid, run}
  end

  defp tick(pid, symbol, price) do
    message =
      %{type: :price, symbol: symbol, source: :ibkr, data: %{last: price}}
      |> Map.put(:__struct__, TradingHub.Message)

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:#{symbol}", message)
    ContractMonitor.snapshot(pid)
  end

  defp rows(run_id),
    do: Repo.all(from l in SimRunStopLadder, where: l.sim_run_id == ^run_id)

  test "rungs keep recording after the real stop, and the run gets its shadow exit" do
    {pid, run} = start_monitor(version_fixture(), "LAD1")

    assert tick(pid, "LAD1", 150.0).position_open?
    # Down hard enough for the real 10% stop.
    refute tick(pid, "LAD1", 145.0).position_open?

    run = Sim.get_sim_run!(run.id)
    assert run.exit_reason == "stop_loss"

    after_stop = rows(run.id)
    assert Enum.any?(after_stop, &(&1.rung_kind == "premium" and &1.rung_value == 10.0))
    refute Enum.any?(after_stop, &(&1.rung_kind == "premium" and is_nil(&1.rung_value)))

    # Flat now (cooldown), but the ladder is still fed: recovery, then the rule exit.
    tick(pid, "LAD1", 152.0)
    refute tick(pid, "LAD1", 139.0).position_open?

    all = rows(run.id)
    assert length(all) == (9 + 4 + 1) * 2
    assert Enum.all?(all, &(&1.mae_pct >= 0 and &1.mfe_pct >= 0))

    none =
      Enum.find(all, &(&1.rung_kind == "premium" and is_nil(&1.rung_value) and not &1.with_tp))

    assert none.exit_reason == "rule"

    run = Sim.get_sim_run!(run.id)
    assert run.context["shadow_exit_reason"] == "rule"
    assert run.context["shadow_r"] == none.r_net
    assert run.context["shadow_exit_price"] == Decimal.to_string(none.exit_price)

    assert Map.get(:sys.get_state(pid), :stop_ladders) == []
  end

  # The rung matching the real controls (SL10, with the target) reproduces
  # the real run's net R to within cost rounding.
  test "the SL10 with-target rung matches the real stop exit" do
    {pid, run} = start_monitor(version_fixture(), "LAD2")

    tick(pid, "LAD2", 150.0)
    tick(pid, "LAD2", 145.0)

    run = Sim.get_sim_run!(run.id)
    real_r = Decimal.to_float(Decimal.div(run.realized_pnl_net, run.risk_at_entry))

    rung =
      Enum.find(
        rows(run.id),
        &(&1.rung_kind == "premium" and &1.rung_value == 10.0 and &1.with_tp)
      )

    assert rung.exit_reason == "stop"
    assert_in_delta rung.r_net, real_r, 0.005
  end
end
