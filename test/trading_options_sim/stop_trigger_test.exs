defmodule TradingOptionsSim.StopTriggerTest do
  # params["stop_trigger"] "mid_confirmed", risk_controls "underlying_atr"
  # and "no_take_profit". async: false: real monitors and a global ATR stub.
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.StrategyVersion

  defmodule StubAtr do
    # Daily ATR 19.5, so the 20-minute ATR is 19.5 x sqrt(20/390) ~ 4.42.
    def lookup(_symbol, _period), do: {:ok, %{atr: Decimal.new("19.5")}}
  end

  setup do
    Application.put_env(:trading_options_sim, :daily_atr_source, StubAtr)
    on_exit(fn -> Application.delete_env(:trading_options_sim, :daily_atr_source) end)
  end

  @t0 ~U[2026-11-27 15:00:00Z]

  # A long call with a 9.00 stop, as confirmed_stop/3 sees it.
  defp stop_state(exit_state \\ %{}) do
    %{
      stop_loss_price: Decimal.new("9.00"),
      direction: "long",
      right: "C",
      symbol: "TRIG",
      expiry: "20271231",
      strike: Decimal.new("150.00"),
      exit_state: exit_state
    }
  end

  defp book(bid, ask), do: %{"run_bid" => bid, "run_ask" => ask, "run_current_price" => bid}

  describe "confirmed_stop/3 (stop_trigger mid_confirmed)" do
    test "a first breach only starts the clock; a second at least 2 s later fires" do
      {false, state} = ContractMonitor.confirmed_stop(stop_state(), book(8.80, 8.90), @t0)
      assert state.exit_state.stop_breach_at == @t0

      later = DateTime.add(@t0, 1, :second)
      assert {false, _} = ContractMonitor.confirmed_stop(state, book(8.80, 8.90), later)

      later = DateTime.add(@t0, 2, :second)
      assert {true, _} = ContractMonitor.confirmed_stop(state, book(8.80, 8.90), later)
    end

    test "a tick back inside the stop resets the clock" do
      {false, state} = ContractMonitor.confirmed_stop(stop_state(), book(8.80, 8.90), @t0)

      {false, state} =
        ContractMonitor.confirmed_stop(state, book(9.10, 9.20), DateTime.add(@t0, 1, :second))

      refute Map.has_key?(state.exit_state, :stop_breach_at)

      assert {false, _} =
               ContractMonitor.confirmed_stop(
                 state,
                 book(8.80, 8.90),
                 DateTime.add(@t0, 3, :second)
               )
    end

    test "judged on the mid, not the last trade: a last print through the stop with the mid above it holds" do
      snapshot = %{"run_bid" => 9.00, "run_ask" => 9.40, "run_current_price" => 8.50}
      {false, state} = ContractMonitor.confirmed_stop(stop_state(), snapshot, @t0)
      refute Map.has_key?(state.exit_state, :stop_breach_at)
    end

    test "a spread wider than 15% of the mid defers the stop" do
      # mid 8.50, spread 2.00 = 23.5% of mid.
      state = stop_state(%{stop_breach_at: DateTime.add(@t0, -10, :second)})
      {false, state} = ContractMonitor.confirmed_stop(state, book(7.50, 9.50), @t0)
      assert state.exit_state.stop_deferrals == 1
      assert state.exit_state.stop_deferred_logged

      # A tradeable quote afterwards fires (the breach clock was kept).
      assert {true, _} = ContractMonitor.confirmed_stop(state, book(8.40, 8.60), @t0)
    end
  end

  defp version_fixture(params) do
    {:ok, strategy} = Sim.create_strategy(%{name: "Stop Trigger"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1},
        rules: %{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 149},
          "exit" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 999_999}
        },
        params: params
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

  describe "risk_controls underlying_atr" do
    @uatr %{
      "method" => "underlying_atr",
      "underlying_atr_mult" => 1.0,
      "stop_loss_percent" => 10,
      "take_profit_percent" => 50
    }

    test "no premium stop; exits once the underlying is 1 x 20m ATR against the position" do
      {pid, run} = start_monitor(version_fixture(%{"risk_controls" => @uatr}), "UATR1")

      assert tick(pid, "UATR1", 150.0).position_open?
      run = Sim.get_sim_run!(run.id)
      assert run.stop_loss_price == nil
      level = run.context["underlying_stop_level"]
      assert_in_delta level, 150.0 - 19.5 * :math.sqrt(20 / 390), 1.0e-9

      # 4.0 down: the premium has fallen more than 10%, but the underlying
      # stop (~4.42) isn't reached, so the position stays open.
      assert tick(pid, "UATR1", 146.0).position_open?
      refute tick(pid, "UATR1", 145.5).position_open?

      run = Sim.get_sim_run!(run.id)
      assert run.exit_reason == "stop_loss"
      assert run.context["stop_kind"] == "underlying"
    end
  end

  describe "risk_controls no_take_profit" do
    test "drops the target and keeps the stop" do
      rc = %{"method" => "percent_of_entry", "stop_loss_percent" => 50, "no_take_profit" => true}
      {pid, run} = start_monitor(version_fixture(%{"risk_controls" => rc}), "NOTP1")

      tick(pid, "NOTP1", 150.0)
      run = Sim.get_sim_run!(run.id)
      assert run.take_profit_price == nil
      assert run.stop_loss_price != nil

      # A big move up that a 20% target would have taken: still open.
      assert tick(pid, "NOTP1", 170.0).position_open?
    end
  end

  describe "params_errors/1" do
    test "accepts the new settings" do
      assert StrategyVersion.params_errors(%{
               "stop_trigger" => "mid_confirmed",
               "risk_controls" => %{
                 "method" => "percent_of_entry",
                 "stop_loss_percent" => 50,
                 "no_take_profit" => true
               }
             }) == []

      assert StrategyVersion.params_errors(%{"risk_controls" => @uatr}) == []
    end

    test "rejects bad ones" do
      assert StrategyVersion.params_errors(%{"stop_trigger" => "mid"}) != []

      # A missing target percent is only allowed with no_take_profit.
      assert StrategyVersion.params_errors(%{
               "risk_controls" => %{"method" => "percent_of_entry", "stop_loss_percent" => 50}
             }) != []

      assert StrategyVersion.params_errors(%{
               "risk_controls" => Map.delete(@uatr, "underlying_atr_mult")
             }) != []
    end
  end
end
