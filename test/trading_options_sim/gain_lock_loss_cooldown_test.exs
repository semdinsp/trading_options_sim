defmodule TradingOptionsSim.GainLockLossCooldownTest do
  # params["gain_lock"] and params["reentry_cooldown_after_loss_seconds"].
  # async: false: real ContractMonitors under the shared registry.
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.StrategyVersion

  @risk %{"method" => "percent_of_entry", "stop_loss_percent" => 10, "take_profit_percent" => 50}

  defp version_fixture(rules, params) do
    {:ok, strategy} = Sim.create_strategy(%{name: "Gain Lock / Loss Cooldown"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1},
        rules: rules,
        params: params
      })

    version
  end

  defp open_run(version, symbol) do
    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: symbol,
        expiry: "20271231",
        strike: Decimal.new("150.00"),
        right: "C",
        multiplier: 100,
        direction: "long"
      })

    run
  end

  # exchange: nil skips session hours, so the test doesn't depend on the clock.
  defp start_monitor(version, symbol) do
    run = open_run(version, symbol)

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

    pid
  end

  defp tick(pid, symbol, price) do
    message =
      %{type: :price, symbol: symbol, source: :ibkr, data: %{last: price}}
      |> Map.put(:__struct__, TradingHub.Message)

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:#{symbol}", message)
    ContractMonitor.snapshot(pid)
  end

  defp current_run(pid), do: Sim.get_sim_run!(ContractMonitor.snapshot(pid).sim_run_id)

  describe "gain_lock_stop/6" do
    test "long: locks lock_r R once the premium is trigger_r R up" do
      entry = Decimal.new("10.00")
      # R = 10% of 10.00 = 1.00: trigger at 10.50, lock at 10.25.
      assert ContractMonitor.gain_lock_stop(entry, Decimal.new("10.49"), "long", 0.5, 0.25, 10) ==
               :no_lock

      assert {:lock, stop} =
               ContractMonitor.gain_lock_stop(entry, Decimal.new("10.50"), "long", 0.5, 0.25, 10)

      assert Decimal.equal?(stop, Decimal.new("10.25"))
    end

    test "lock_r 0 is breakeven" do
      assert {:lock, stop} =
               ContractMonitor.gain_lock_stop(
                 Decimal.new("8.00"),
                 Decimal.new("9.00"),
                 "long",
                 0.75,
                 0,
                 10
               )

      assert Decimal.equal?(stop, Decimal.new("8.00"))
    end

    test "short: the favourable move is down" do
      entry = Decimal.new("10.00")

      assert ContractMonitor.gain_lock_stop(entry, Decimal.new("10.60"), "short", 0.5, 0.25, 10) ==
               :no_lock

      assert {:lock, stop} =
               ContractMonitor.gain_lock_stop(entry, Decimal.new("9.50"), "short", 0.5, 0.25, 10)

      assert Decimal.equal?(stop, Decimal.new("9.75"))
    end
  end

  describe "gain_lock on a live monitor" do
    @hold %{
      "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 149},
      "exit" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 999_999}
    }

    test "moves the stop to lock the gain, keeps the take profit, and exits as gain_lock" do
      gain_lock = %{"trigger_r" => 0.5, "lock_r" => 0.25}
      version = version_fixture(@hold, %{"risk_controls" => @risk, "gain_lock" => gain_lock})
      pid = start_monitor(version, "GLOCK1")

      assert tick(pid, "GLOCK1", 150.0).position_open?
      run = current_run(pid)
      entry = run.entry_price
      initial_tp = run.take_profit_price

      tick(pid, "GLOCK1", 158.0)
      run = Sim.get_sim_run!(run.id)
      lock = entry |> Decimal.mult(Decimal.new("1.025")) |> Decimal.round(2)

      assert Decimal.equal?(run.stop_loss_price, lock)
      assert Decimal.equal?(run.take_profit_price, initial_tp)

      # Back to the entry spot: the premium is under the locked stop.
      refute tick(pid, "GLOCK1", 150.0).position_open?
      run = Sim.get_sim_run!(run.id)
      assert run.exit_reason == "stop_loss"
      assert run.context["stop_kind"] == "gain_lock"
    end

    # Healthy input: a move short of the trigger leaves the initial stop.
    test "a move short of the trigger leaves the initial stop alone" do
      gain_lock = %{"trigger_r" => 0.5, "lock_r" => 0.25}
      version = version_fixture(@hold, %{"risk_controls" => @risk, "gain_lock" => gain_lock})
      pid = start_monitor(version, "GLOCK2")

      tick(pid, "GLOCK2", 150.0)
      run = current_run(pid)
      initial_stop = run.stop_loss_price

      tick(pid, "GLOCK2", 150.3)
      assert Decimal.equal?(Sim.get_sim_run!(run.id).stop_loss_price, initial_stop)
      assert ContractMonitor.snapshot(pid).position_open?
    end
  end

  describe "cooled_down?/2 with a loss cooldown" do
    setup do
      now = DateTime.utc_now()
      %{now: now, exited: DateTime.add(now, -120, :second)}
    end

    test "a losing exit uses the loss cooldown", %{now: now, exited: exited} do
      state = %{
        reentry_cooldown_seconds: 60,
        reentry_cooldown_after_loss: 300,
        last_exit_at: exited,
        last_exit_loss?: true
      }

      refute ContractMonitor.cooled_down?(state, now)
    end

    test "a winning exit keeps the plain cooldown", %{now: now, exited: exited} do
      state = %{
        reentry_cooldown_seconds: 60,
        reentry_cooldown_after_loss: 300,
        last_exit_at: exited,
        last_exit_loss?: false
      }

      assert ContractMonitor.cooled_down?(state, now)
    end

    test "a loss cooldown works with no plain cooldown", %{now: now, exited: exited} do
      blocked = %{
        reentry_cooldown_seconds: 0,
        reentry_cooldown_after_loss: 300,
        last_exit_at: exited,
        last_exit_loss?: true
      }

      refute ContractMonitor.cooled_down?(blocked, now)
      assert ContractMonitor.cooled_down?(%{blocked | last_exit_loss?: false}, now)
    end

    test "rest_of_session blocks until the next New York date" do
      # 2026-11-25 10:36 ET exit; 15:59 ET same day vs 09:30 ET next session.
      exited = ~U[2026-11-25 15:36:00Z]

      state = %{
        reentry_cooldown_seconds: 1800,
        reentry_cooldown_after_loss: :rest_of_session,
        last_exit_at: exited,
        last_exit_loss?: true
      }

      refute ContractMonitor.cooled_down?(state, ~U[2026-11-25 20:59:00Z])
      assert ContractMonitor.cooled_down?(state, ~U[2026-11-27 14:30:00Z])
    end

    # A monitor started before the new fields existed has neither key.
    test "a state without the new keys behaves as before", %{now: now, exited: exited} do
      refute ContractMonitor.cooled_down?(
               %{reentry_cooldown_seconds: 300, last_exit_at: exited},
               now
             )
    end
  end

  describe "loss cooldown on a live monitor" do
    # Call: enter above 149; exit below 145 (a loss) or above 160 (a win).
    @round_trip %{
      "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 149},
      "exit" => %{
        "any" => [
          %{"signal" => "run_underlying_price", "op" => "lt", "value" => 145},
          %{"signal" => "run_underlying_price", "op" => "gt", "value" => 160}
        ]
      }
    }

    test "after a losing exit the next true tick doesn't re-enter" do
      version = version_fixture(@round_trip, %{"reentry_cooldown_after_loss_seconds" => 300})
      pid = start_monitor(version, "LCOOL1")

      assert tick(pid, "LCOOL1", 150.0).position_open?
      refute tick(pid, "LCOOL1", 140.0).position_open?
      refute tick(pid, "LCOOL1", 150.0).position_open?
    end

    # Healthy input: the same version re-enters after a winning exit.
    test "after a winning exit it re-enters" do
      version = version_fixture(@round_trip, %{"reentry_cooldown_after_loss_seconds" => 300})
      pid = start_monitor(version, "LCOOL2")

      assert tick(pid, "LCOOL2", 150.0).position_open?
      refute tick(pid, "LCOOL2", 165.0).position_open?
      assert tick(pid, "LCOOL2", 155.0).position_open?
    end
  end

  describe "seed_last_exit/2" do
    test "a restart remembers that the last exit lost" do
      version = version_fixture(@hold, %{"reentry_cooldown_after_loss_seconds" => 300})
      run = open_run(version, "SEED1")
      at = DateTime.add(DateTime.utc_now(), -30, :second)

      {:ok, {_fill, run}} =
        Sim.record_entry_fill(
          run,
          %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: at},
          %{entry_at: at, entry_price: Decimal.new("5.00")}
        )

      {:ok, _} =
        Sim.record_exit_fill(
          run,
          %{action: "sell", quantity: 1, fill_price: Decimal.new("4.00"), filled_at: at},
          %{
            exit_at: at,
            exit_price: Decimal.new("4.00"),
            exit_reason: "rule_exit",
            realized_pnl: Decimal.new("-100")
          }
        )

      assert %{last_exit_loss?: true, last_exit_at: %DateTime{}} =
               ContractMonitor.seed_last_exit(version, "SEED1")

      pid = start_monitor(version, "SEED1")
      refute tick(pid, "SEED1", 150.0).position_open?
    end
  end

  describe "params_errors/1" do
    test "accepts the new params" do
      assert StrategyVersion.params_errors(%{
               "risk_controls" => @risk,
               "gain_lock" => %{"trigger_r" => 0.75, "lock_r" => 0},
               "reentry_cooldown_after_loss_seconds" => "rest_of_session"
             }) == []

      assert StrategyVersion.params_errors(%{"reentry_cooldown_after_loss_seconds" => 3600}) ==
               []
    end

    test "rejects bad shapes" do
      assert StrategyVersion.params_errors(%{"reentry_cooldown_after_loss_seconds" => "1h"}) != []

      assert StrategyVersion.params_errors(%{
               "risk_controls" => @risk,
               "gain_lock" => %{"trigger_r" => 0.5, "lock_r" => 0.5}
             }) != []

      # R needs a stop distance.
      assert StrategyVersion.params_errors(%{"gain_lock" => %{"trigger_r" => 0.5, "lock_r" => 0}}) !=
               []
    end
  end
end
