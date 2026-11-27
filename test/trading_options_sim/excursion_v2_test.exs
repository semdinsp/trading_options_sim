defmodule TradingOptionsSim.ExcursionV2Test do
  # Excursion v2: mfe_pct / mae_pct on mid, from entry, never negative,
  # with the underlying at entry, MAE, MFE and exit.
  # async: false: real ContractMonitors under the shared registry.
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.Sim

  defp version_fixture(rules) do
    {:ok, strategy} = Sim.create_strategy(%{name: "Excursion v2"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1},
        rules: rules,
        params: %{}
      })

    version
  end

  # exchange: nil skips session hours, so the test doesn't depend on the clock.
  defp start_monitor(version, symbol, right) do
    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: symbol,
        expiry: "20271231",
        strike: Decimal.new("150.00"),
        right: right,
        multiplier: 100,
        direction: "long"
      })

    {:ok, pid} =
      start_supervised(
        {ContractMonitor,
         sim_run_id: run.id,
         contract_key: {symbol, "20271231", Decimal.new("150.00"), right},
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

  defp rules(entry_op, entry_value, exit_op, exit_value) do
    %{
      "entry" => %{"signal" => "run_underlying_price", "op" => entry_op, "value" => entry_value},
      "exit" => %{"signal" => "run_underlying_price", "op" => exit_op, "value" => exit_value}
    }
  end

  test "long call: up then down gives a positive MFE and MAE, with the underlying at each" do
    {pid, run} = start_monitor(version_fixture(rules("gt", 149, "lt", 146)), "XV1", "C")

    tick(pid, "XV1", 150.0)
    tick(pid, "XV1", 156.0)
    tick(pid, "XV1", 147.0)
    refute tick(pid, "XV1", 145.0).position_open?

    ctx = Sim.get_sim_run!(run.id).context
    assert ctx["excursion_version"] == 2
    assert ctx["mfe_pct"] > 0
    assert ctx["mae_pct"] > 0
    assert ctx["underlying_at_entry"] == 150.0
    assert ctx["underlying_at_mfe"] == 156.0
    assert ctx["underlying_at_mae"] == 145.0
    assert ctx["underlying_at_exit"] == 145.0
  end

  test "long put: the favourable move is the underlying falling" do
    {pid, run} = start_monitor(version_fixture(rules("lt", 151, "gt", 154)), "XV2", "P")

    tick(pid, "XV2", 150.0)
    tick(pid, "XV2", 144.0)
    refute tick(pid, "XV2", 155.0).position_open?

    ctx = Sim.get_sim_run!(run.id).context
    assert ctx["mfe_pct"] > 0
    assert ctx["mae_pct"] > 0
    assert ctx["underlying_at_mfe"] == 144.0
    assert ctx["underlying_at_mae"] == 155.0
  end

  # The v1 defect: a premium that never trades below entry gave a
  # negative MAE (and one that never traded above it a negative MFE).
  test "a run that only went up has mae_pct 0, never negative" do
    {pid, run} = start_monitor(version_fixture(rules("gt", 149, "gt", 157)), "XV3", "C")

    tick(pid, "XV3", 150.0)
    tick(pid, "XV3", 154.0)
    refute tick(pid, "XV3", 158.0).position_open?

    ctx = Sim.get_sim_run!(run.id).context
    assert ctx["mae_pct"] == 0.0
    assert ctx["mfe_pct"] > 0
  end

  test "a run that only went down has mfe_pct 0, never negative" do
    {pid, run} = start_monitor(version_fixture(rules("gt", 149, "lt", 146)), "XV4", "C")

    tick(pid, "XV4", 150.0)
    tick(pid, "XV4", 148.0)
    refute tick(pid, "XV4", 145.0).position_open?

    ctx = Sim.get_sim_run!(run.id).context
    assert ctx["mfe_pct"] == 0.0
    assert ctx["mae_pct"] > 0
  end
end
