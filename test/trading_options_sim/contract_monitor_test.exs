defmodule TradingOptionsSim.ContractMonitorTest do
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.SignalBus.Test, as: SignalBusTest

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

  # An always-open session (every day of the week, 00:00-23:59) so
  # session_open?/1 never blocks a fill on wall-clock timing during a
  # test run — every existing entry/exit test in this file predates
  # exchange-hours gating and asserts on rule-triggered transitions
  # firing immediately, which this fixture preserves. A test that
  # specifically wants to exercise the closed-session path builds its
  # own narrower session instead (see "exchange hours" describe block).
  defp always_open_exchange_fixture do
    exchange = "TEST_ALWAYS_OPEN_#{System.unique_integer([:positive])}"

    {:ok, hours} =
      %TradingOptionsSim.Sim.ExchangeTradingHours{}
      |> TradingOptionsSim.Sim.ExchangeTradingHours.changeset(%{
        name: exchange,
        timezone: "Etc/UTC",
        start_time: ~T[00:00:00],
        end_time: ~T[23:59:59],
        enabled: true,
        days_of_week: [1, 2, 3, 4, 5, 6, 7]
      })
      |> TradingOptionsSim.Repo.insert()

    {:ok, _session} =
      %TradingOptionsSim.Sim.ExchangeSession{}
      |> TradingOptionsSim.Sim.ExchangeSession.changeset(%{
        exchange: exchange,
        exchange_trading_hours_id: hours.id
      })
      |> TradingOptionsSim.Repo.insert()

    exchange
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
          quantity: 1,
          exchange: always_open_exchange_fixture()
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

  describe "exchange hours" do
    defp closed_exchange_fixture do
      exchange = "TEST_ALWAYS_CLOSED_#{System.unique_integer([:positive])}"

      {:ok, hours} =
        %TradingOptionsSim.Sim.ExchangeTradingHours{}
        |> TradingOptionsSim.Sim.ExchangeTradingHours.changeset(%{
          name: exchange,
          timezone: "Etc/UTC",
          start_time: ~T[00:00:00],
          end_time: ~T[23:59:59],
          enabled: false,
          days_of_week: [1, 2, 3, 4, 5, 6, 7]
        })
        |> TradingOptionsSim.Repo.insert()

      {:ok, _session} =
        %TradingOptionsSim.Sim.ExchangeSession{}
        |> TradingOptionsSim.Sim.ExchangeSession.changeset(%{
          exchange: exchange,
          exchange_trading_hours_id: hours.id
        })
        |> TradingOptionsSim.Repo.insert()

      exchange
    end

    test "does not record a fill when the exchange session is closed" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      symbol = "HOURSTEST1"
      key = contract_key(symbol)
      {pid, run} = start_monitor(version, key, exchange: closed_exchange_fixture())

      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      assert ContractMonitor.snapshot(pid).position_open? == false
      assert Sim.list_sim_fills(run) == []
    end

    test "still updates last_snapshot while the session is closed (observation always runs)" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      symbol = "HOURSTEST2"
      key = contract_key(symbol)
      {pid, _run} = start_monitor(version, key, exchange: closed_exchange_fixture())

      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      snapshot = ContractMonitor.snapshot(pid)
      assert snapshot.position_open? == false
      assert snapshot.last_snapshot["run_underlying_price"] == 150.0
    end

    test "records a fill once the session reopens" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      symbol = "HOURSTEST3"
      key = contract_key(symbol)
      exchange = closed_exchange_fixture()
      {pid, run} = start_monitor(version, key, exchange: exchange)

      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)
      assert ContractMonitor.snapshot(pid).position_open? == false

      {:ok, hours} =
        TradingOptionsSim.Sim.ExchangeSession
        |> TradingOptionsSim.Repo.get_by!(exchange: exchange)
        |> TradingOptionsSim.Repo.preload(:exchange_trading_hours)
        |> Map.fetch!(:exchange_trading_hours)
        |> TradingOptionsSim.Sim.ExchangeTradingHours.changeset(%{enabled: true})
        |> TradingOptionsSim.Repo.update()

      refute hours.enabled == false

      broadcast_underlying_price(symbol, 151.0)
      Process.sleep(50)

      assert ContractMonitor.snapshot(pid).position_open? == true
      assert length(Sim.list_sim_fills(run)) == 1
    end

    test "fails closed when :exchange is nil" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      symbol = "HOURSTEST4"
      key = contract_key(symbol)
      {pid, run} = start_monitor(version, key, exchange: nil)

      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      assert ContractMonitor.snapshot(pid).position_open? == false
      assert Sim.list_sim_fills(run) == []
    end

    test "fails closed when the exchange has no mapped session" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      symbol = "HOURSTEST5"
      key = contract_key(symbol)
      {pid, run} = start_monitor(version, key, exchange: "UNMAPPED_EXCHANGE")

      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      assert ContractMonitor.snapshot(pid).position_open? == false
      assert Sim.list_sim_fills(run) == []
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

  describe "trading_signal integration" do
    setup do
      SignalBusTest.reset()
      :ok
    end

    test "resolves and subscribes to every signal referenced in entry/exit rules on init" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "vix_last", "op" => "gt", "value" => 20},
          "exit" => %{"signal" => "spy_trend_score", "op" => "lt", "value" => 0}
        })

      key = contract_key("SIGNALTEST1")
      {_pid, _run} = start_monitor(version, key)

      assert Enum.sort(SignalBusTest.requested_names()) == ["spy_trend_score", "vix_last"]
    end

    test "a received signal value is merged into the rule-evaluation snapshot on the next price tick" do
      SignalBusTest.stub_topic("vix_last", "signals:vix_last_test_topic")

      version =
        version_fixture(%{
          "entry" => %{"signal" => "vix_last", "op" => "gt", "value" => 20}
        })

      symbol = "SIGNALTEST2"
      key = contract_key(symbol)
      {pid, run} = start_monitor(version, key)

      # Give init/1's subscribe_to_signals/1 a moment to run before
      # broadcasting — it happens synchronously in init, but
      # start_supervised/1 itself already waits for init/1 to return, so
      # this subscription is guaranteed to exist by the time start_monitor
      # returns.
      Phoenix.PubSub.broadcast(
        TradingSignal.PubSub,
        "signals:vix_last_test_topic",
        {:signal, "vix_last_test_topic", 25.0}
      )

      Process.sleep(30)

      # Entry rule isn't satisfied yet — the signal value alone doesn't
      # trigger evaluation, same as an IBKRLive greeks tick.
      assert ContractMonitor.snapshot(pid).position_open? == false

      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      assert ContractMonitor.snapshot(pid).position_open? == true
      assert Sim.list_sim_fills(run) |> length() == 1
    end

    test "re-subscribes on :trading_signal_connected" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "vix_last", "op" => "gt", "value" => 20}
        })

      key = contract_key("SIGNALTEST3")
      {pid, _run} = start_monitor(version, key)

      SignalBusTest.reset()
      send(pid, :trading_signal_connected)
      Process.sleep(30)

      assert SignalBusTest.requested_names() == ["vix_last"]
    end
  end
end
