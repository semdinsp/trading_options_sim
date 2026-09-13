defmodule TradingOptionsSim.ContractMonitorTest do
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.Sim

  # async: false — every monitor in this test subscribes to the same
  # real TradingOptionsSim.PubSub server; broadcasting a price for
  # "AAPL" from one test could otherwise reach a monitor left running
  # from a concurrently-running test using the same symbol.

  defp version_fixture(rules) do
    {:ok, strategy} = Sim.create_strategy(%{name: "Test Strategy"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1},
        rules: rules
      })

    version
  end

  # Far-dated expiry so days_to_expiry/1 never hits the force-close path
  # during a normal test run.
  defp contract_key(symbol) do
    {symbol, "20271231", Decimal.new("150.00"), "C"}
  end

  defp start_monitor(version, contract_key, opts \\ []) do
    {symbol, expiry, strike, right} = contract_key

    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: symbol,
        expiry: expiry,
        strike: strike,
        right: right,
        multiplier: 100,
        direction: Keyword.get(opts, :direction, "long")
      })

    start_opts =
      Keyword.merge(
        [
          sim_run_id: run.id,
          contract_key: contract_key,
          strategy_version: version,
          direction: Keyword.get(opts, :direction, "long"),
          quantity: 1
        ],
        opts
      )

    {:ok, pid} = start_supervised({ContractMonitor, start_opts})
    {pid, run}
  end

  defp broadcast_underlying_price(symbol, last) do
    message =
      %{type: :price, symbol: symbol, source: :ibkr, data: %{last: last}}
      |> Map.put(:__struct__, TradingHub.Message)

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:#{symbol}", message)
  end

  describe "registry_key/2 and whereis/2" do
    test "a started monitor can be looked up via whereis/2" do
      version = version_fixture(%{})
      key = contract_key("REGKEY1")
      {pid, run} = start_monitor(version, key)

      assert ContractMonitor.whereis(run.id, key) == pid
    end
  end

  describe "entry rule transition" do
    test "opens a position and records an entry fill when the entry rule is satisfied" do
      # Entry rule: enter whenever the underlying price is above 100 —
      # trivially satisfied by any positive tick, so the first price
      # broadcast should trigger entry.
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      symbol = "ENTRYTEST1"
      key = contract_key(symbol)
      {pid, run} = start_monitor(version, key)

      broadcast_underlying_price(symbol, 150.0)

      # Give the async handle_info a moment to process and write.
      Process.sleep(50)

      snapshot = ContractMonitor.snapshot(pid)
      assert snapshot.position_open? == true

      fills = Sim.list_sim_fills(run)
      assert length(fills) == 1
      assert hd(fills).kind == "entry"
    end

    test "does not enter when the entry rule is not satisfied" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 1000}
        })

      symbol = "ENTRYTEST2"
      key = contract_key(symbol)
      {pid, run} = start_monitor(version, key)

      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      snapshot = ContractMonitor.snapshot(pid)
      assert snapshot.position_open? == false
      assert Sim.list_sim_fills(run) == []
    end
  end

  describe "exit rule transition" do
    test "closes an open position and records an exit fill when the exit rule is satisfied" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100},
          "exit" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 140}
        })

      symbol = "EXITTEST1"
      key = contract_key(symbol)
      {pid, run} = start_monitor(version, key)

      # First tick enters (satisfies entry, not yet exit).
      broadcast_underlying_price(symbol, 130.0)
      Process.sleep(50)
      assert ContractMonitor.snapshot(pid).position_open? == true

      # Second tick satisfies exit.
      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      snapshot = ContractMonitor.snapshot(pid)
      assert snapshot.position_open? == false

      fills = Sim.list_sim_fills(run)
      assert length(fills) == 2
      assert Enum.map(fills, & &1.kind) == ["entry", "exit"]

      closed_run = Sim.get_sim_run!(run.id)
      assert closed_run.status == "closed"
      assert closed_run.exit_reason == "rule_exit"
    end
  end

  describe "short direction" do
    test "records buy/sell actions in the opposite order for a short position" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      symbol = "SHORTTEST1"
      key = contract_key(symbol)
      {_pid, run} = start_monitor(version, key, direction: "short")

      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      fills = Sim.list_sim_fills(run)
      assert length(fills) == 1
      assert hd(fills).action == "sell"
    end
  end

  describe "expiry handling" do
    test "force-closes an open position at or past the expiry cutoff" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      symbol = "EXPIRYTEST1"
      # Expiry is today (0 DTE) — days_to_expiry/1 returns 0, which is
      # <= the default expiry_close_dte cutoff of 1, so an already-open
      # position should force-close on the very next tick, not enter.
      today = Date.utc_today() |> Date.to_string() |> String.replace("-", "")
      key = {symbol, today, Decimal.new("150.00"), "C"}

      {:ok, run} =
        Sim.open_sim_run(version, %{
          symbol: symbol,
          expiry: today,
          strike: Decimal.new("150.00"),
          right: "C",
          multiplier: 100,
          direction: "long"
        })

      now = DateTime.utc_now()

      {:ok, {_fill, run}} =
        Sim.record_entry_fill(
          run,
          %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: now},
          %{entry_at: now, entry_price: Decimal.new("5.00")}
        )

      {:ok, _pid} =
        start_supervised(
          {ContractMonitor,
           sim_run_id: run.id,
           contract_key: key,
           strategy_version: version,
           direction: "long",
           quantity: 1,
           position_open?: true}
        )

      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      closed_run = Sim.get_sim_run!(run.id)
      assert closed_run.status == "closed"
      assert closed_run.exit_reason == "expiry"
    end
  end

  describe ":ibkr_live pricing backend" do
    defp broadcast_option_greeks(occ_symbol, data) do
      message =
        %{type: :price, symbol: occ_symbol, source: :ibkr, data: data}
        |> Map.put(:__struct__, TradingHub.Message)

      Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:#{occ_symbol}", message)
    end

    test "does not evaluate (stays flat) until a real greeks tick arrives" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      symbol = "IBKRLIVE1"
      occ_symbol = "IBKRLIVE1_OCC"
      key = contract_key(symbol)

      {pid, run} =
        start_monitor(version, key, pricing_backend: :ibkr_live, occ_symbol: occ_symbol)

      # An underlying tick arrives, but IBKRLive has no data yet for this
      # contract — must not enter, must not fall back to Black-Scholes.
      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      assert ContractMonitor.snapshot(pid).position_open? == false
      assert Sim.list_sim_fills(run) == []
    end

    test "enters using the real greeks tick's own price, once one arrives" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      symbol = "IBKRLIVE2"
      occ_symbol = "IBKRLIVE2_OCC"
      key = contract_key(symbol)

      {pid, run} =
        start_monitor(version, key, pricing_backend: :ibkr_live, occ_symbol: occ_symbol)

      broadcast_option_greeks(occ_symbol, %{
        implied_vol: 0.30,
        delta: 0.55,
        opt_price: 6.25,
        gamma: 0.02,
        vega: 0.15,
        theta: -0.03,
        und_price: 150.0
      })

      Process.sleep(50)

      # The greeks tick alone doesn't trigger evaluation (per design,
      # evaluation is driven by the underlying's own tick, reading
      # whatever IBKRLive has cached) — a subsequent underlying tick is
      # what actually fires the rule check.
      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      assert ContractMonitor.snapshot(pid).position_open? == true

      fills = Sim.list_sim_fills(run)
      assert length(fills) == 1
      assert Decimal.equal?(hd(fills).fill_price, Decimal.new("6.25"))
    end

    test "raises if :occ_symbol is missing for :ibkr_live" do
      version = version_fixture(%{})
      key = contract_key("IBKRLIVE3")

      {:ok, run} =
        Sim.open_sim_run(version, %{
          symbol: "IBKRLIVE3",
          expiry: "20271231",
          strike: Decimal.new("150.00"),
          right: "C",
          multiplier: 100,
          direction: "long"
        })

      assert {:error, {{%ArgumentError{}, _init_stacktrace}, _child_spec}} =
               start_supervised(
                 {ContractMonitor,
                  sim_run_id: run.id,
                  contract_key: key,
                  strategy_version: version,
                  direction: "long",
                  quantity: 1,
                  pricing_backend: :ibkr_live}
               )
    end
  end
end
