defmodule TradingOptionsSim.ChurnFiltersTest do
  # params["entry_confirm_seconds"] and params["reentry_cooldown_seconds"].
  # async: false: real ContractMonitors under the shared registry.
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.StrategyVersion

  # Entry when the underlying is above 149; tick at 150 for true, 140 for false.
  @rules %{
    "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 149},
    "exit" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 999_999}
  }

  defp version_fixture(params) do
    {:ok, strategy} = Sim.create_strategy(%{name: "Churn Filters"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1},
        rules: @rules,
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

  # A closed, entered run for `symbol` that exited `seconds_ago`.
  defp closed_run(version, symbol, seconds_ago) do
    run = open_run(version, symbol)
    at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    {:ok, {_fill, run}} =
      Sim.record_entry_fill(
        run,
        %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: at},
        %{entry_at: at, entry_price: Decimal.new("5.00")}
      )

    {:ok, _} =
      Sim.record_exit_fill(
        run,
        %{action: "sell", quantity: 1, fill_price: Decimal.new("5.10"), filled_at: at},
        %{
          exit_at: at,
          exit_price: Decimal.new("5.10"),
          exit_reason: "rule_exit",
          realized_pnl: Decimal.new("10")
        }
      )
  end

  # exchange: nil skips session hours, so only the churn filters gate entry.
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
    _ = ContractMonitor.snapshot(pid)
  end

  defp open?(pid), do: ContractMonitor.snapshot(pid).position_open?

  describe "entry_confirmed?/2" do
    test "no confirmation configured is always confirmed" do
      assert ContractMonitor.entry_confirmed?(
               %{entry_confirm_seconds: 0, entry_true_since: nil},
               DateTime.utc_now()
             )
    end

    test "false while the rule hasn't held long enough, true once it has" do
      now = DateTime.utc_now()
      since = DateTime.add(now, -10, :second)

      refute ContractMonitor.entry_confirmed?(
               %{entry_confirm_seconds: 30, entry_true_since: since},
               now
             )

      assert ContractMonitor.entry_confirmed?(
               %{entry_confirm_seconds: 5, entry_true_since: since},
               now
             )

      refute ContractMonitor.entry_confirmed?(
               %{entry_confirm_seconds: 5, entry_true_since: nil},
               now
             )
    end
  end

  describe "cooled_down?/2" do
    test "no cooldown, or no previous exit, never blocks" do
      now = DateTime.utc_now()
      assert ContractMonitor.cooled_down?(%{reentry_cooldown_seconds: 0, last_exit_at: now}, now)

      assert ContractMonitor.cooled_down?(
               %{reentry_cooldown_seconds: 300, last_exit_at: nil},
               now
             )
    end

    test "blocks inside the cooldown and allows after it" do
      now = DateTime.utc_now()
      exited = DateTime.add(now, -60, :second)

      refute ContractMonitor.cooled_down?(
               %{reentry_cooldown_seconds: 300, last_exit_at: exited},
               now
             )

      assert ContractMonitor.cooled_down?(
               %{reentry_cooldown_seconds: 30, last_exit_at: exited},
               now
             )
    end
  end

  describe "entry confirmation on a live monitor" do
    test "does not enter on the first true tick" do
      pid = start_monitor(version_fixture(%{"entry_confirm_seconds" => 60}), "CONFIRM1")
      tick(pid, "CONFIRM1", 150.0)
      refute open?(pid)
    end

    # The rule held for the full window: enters (healthy-input case).
    test "enters once the rule has held for the confirmation window" do
      pid = start_monitor(version_fixture(%{"entry_confirm_seconds" => 1}), "CONFIRM2")
      tick(pid, "CONFIRM2", 150.0)
      Process.sleep(1_100)
      tick(pid, "CONFIRM2", 150.0)
      assert open?(pid)
    end

    # A flicker restarts the clock: true, false, then true again after
    # the window has passed since the FIRST true still doesn't enter.
    test "a false tick in between restarts the confirmation clock" do
      pid = start_monitor(version_fixture(%{"entry_confirm_seconds" => 1}), "CONFIRM3")
      tick(pid, "CONFIRM3", 150.0)
      tick(pid, "CONFIRM3", 140.0)
      Process.sleep(1_100)
      tick(pid, "CONFIRM3", 150.0)
      refute open?(pid)
    end
  end

  describe "re-entry cooldown on a live monitor" do
    test "a monitor started inside the cooldown of its last exit does not enter" do
      version = version_fixture(%{"reentry_cooldown_seconds" => 300})
      closed_run(version, "COOL1", 30)
      pid = start_monitor(version, "COOL1")

      tick(pid, "COOL1", 150.0)
      refute open?(pid)
    end

    test "after the cooldown has passed it enters" do
      version = version_fixture(%{"reentry_cooldown_seconds" => 10})
      closed_run(version, "COOL2", 30)
      pid = start_monitor(version, "COOL2")

      tick(pid, "COOL2", 150.0)
      assert open?(pid)
    end
  end

  describe "re-entry cooldown after an in-session exit" do
    # Enter above 149, exit below 145.
    @round_trip %{
      "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 149},
      "exit" => %{"signal" => "run_underlying_price", "op" => "lt", "value" => 145}
    }

    defp round_trip_version(params) do
      {:ok, strategy} = Sim.create_strategy(%{name: "Churn Round Trip"})

      {:ok, version} =
        Sim.create_strategy_version(strategy, %{
          version: 1,
          position_sizing: %{"method" => "fixed_qty", "qty" => 1},
          rules: @round_trip,
          params: params
        })

      version
    end

    test "an exit starts the cooldown, so the next true tick doesn't re-enter" do
      pid = start_monitor(round_trip_version(%{"reentry_cooldown_seconds" => 300}), "COOL3")
      tick(pid, "COOL3", 150.0)
      assert open?(pid)
      tick(pid, "COOL3", 140.0)
      refute open?(pid)
      tick(pid, "COOL3", 150.0)
      refute open?(pid)
    end

    # Healthy input: without a cooldown the same sequence re-enters.
    test "without a cooldown the same sequence re-enters" do
      pid = start_monitor(round_trip_version(%{}), "COOL4")
      tick(pid, "COOL4", 150.0)
      tick(pid, "COOL4", 140.0)
      tick(pid, "COOL4", 150.0)
      assert open?(pid)
    end
  end

  describe "params validation" do
    test "accepts non-negative integers and rejects anything else" do
      assert StrategyVersion.params_errors(%{
               "entry_confirm_seconds" => 30,
               "reentry_cooldown_seconds" => 0
             }) == []

      assert StrategyVersion.params_errors(%{"entry_confirm_seconds" => -1}) != []
      assert StrategyVersion.params_errors(%{"reentry_cooldown_seconds" => "300"}) != []
    end
  end
end
