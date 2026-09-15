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
      {pid, _run} = start_monitor(version, key)

      assert ContractMonitor.whereis(version.id, key) == pid
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

    test "re-entering after a natural exit (no reactivation) opens a NEW SimRun, not the closed one" do
      # Confirmed live 2026-09-15 as a real, serious bug distinct from
      # the earlier sim_run_id-staleness one (that fix only covers
      # SimActivator's own "reuse an already-running monitor for a NEW
      # activation" path — see update_sim_run_id/2's own doc). A
      # monitor that goes flat and re-enters entirely on its own, with
      # no activate/1 call in between, had no mechanism to open a fresh
      # SimRun at all: every entry after the very first one kept
      # writing onto the SAME already-closed run row (entry_changeset/2
      # never touches `status`), silently accumulating dozens of
      # SimFill rows under one run whose own total_run_commission then
      # summed every one of them. One real version was found with 51
      # fills (26 entry/25 exit) on a single SimRun after ~3 minutes of
      # a fast-oscillating signal.
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100},
          "exit" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 140}
        })

      symbol = "EXITTEST3"
      key = contract_key(symbol)
      {pid, first_run} = start_monitor(version, key)

      # Cycle 1: enter, then exit.
      broadcast_underlying_price(symbol, 130.0)
      Process.sleep(50)
      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)
      assert Sim.get_sim_run!(first_run.id).status == "closed"

      # Cycle 2: re-enter on the SAME monitor — no SimActivator.activate/1
      # call anywhere in this test, purely rule-driven oscillation.
      broadcast_underlying_price(symbol, 130.0)
      Process.sleep(50)
      assert ContractMonitor.snapshot(pid).position_open? == true

      # The first run must be untouched — still closed, still exactly 2
      # fills (its own entry+exit), not resurrected by the second entry.
      reloaded_first_run = Sim.get_sim_run!(first_run.id)
      assert reloaded_first_run.status == "closed"
      assert length(Sim.list_sim_fills(reloaded_first_run)) == 2

      # A genuinely new, second SimRun must now be open.
      [second_run] = Sim.list_open_sim_runs(version)
      assert second_run.id != first_run.id
      assert length(Sim.list_sim_fills(second_run)) == 1

      # Cycle 3: exit again, so total_run_commission on the FIRST run
      # only reflects its own 2 fills, never the second run's.
      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      first_fills = Sim.list_sim_fills(Sim.get_sim_run!(first_run.id))
      second_fills = Sim.list_sim_fills(Sim.get_sim_run!(second_run.id))
      assert length(first_fills) == 2
      assert length(second_fills) == 2
      refute Sim.get_sim_run!(first_run.id).id == Sim.get_sim_run!(second_run.id).id
    end

    test "the monitor stays discoverable via whereis/2 after its run closes" do
      # Confirmed live 2026-09-15: whereis/2 used to be keyed by
      # {sim_run_id, contract_key} — once a run closed, its still-alive,
      # still-watching monitor became permanently undiscoverable by
      # anything that only had the (now-closed) run's own id to look it
      # up by. Re-keyed by {strategy_version_id, contract_key} (see
      # ContractMonitor.registry_key/2's own doc) precisely so this
      # stays true.
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100},
          "exit" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 140}
        })

      symbol = "EXITTEST2"
      key = contract_key(symbol)
      {pid, run} = start_monitor(version, key)

      broadcast_underlying_price(symbol, 130.0)
      Process.sleep(50)
      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      assert Sim.get_sim_run!(run.id).status == "closed"
      assert Process.alive?(pid)
      assert ContractMonitor.whereis(version.id, key) == pid
    end
  end

  describe "commission tracking" do
    test "estimates and stores commission on both the entry and exit fill" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100},
          "exit" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 140}
        })

      symbol = "COMMISSIONTEST1"
      key = contract_key(symbol)
      {_pid, run} = start_monitor(version, key)

      broadcast_underlying_price(symbol, 130.0)
      Process.sleep(50)
      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      [entry_fill, exit_fill] = Sim.list_sim_fills(run)

      refute is_nil(entry_fill.commission)
      refute is_nil(exit_fill.commission)
      assert Decimal.compare(entry_fill.commission, Decimal.new(0)) == :gt
      assert Decimal.compare(exit_fill.commission, Decimal.new(0)) == :gt
    end

    test "sets realized_pnl_net to realized_pnl minus the summed entry+exit commission" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100},
          "exit" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 140}
        })

      symbol = "COMMISSIONTEST2"
      key = contract_key(symbol)
      {_pid, run} = start_monitor(version, key)

      broadcast_underlying_price(symbol, 130.0)
      Process.sleep(50)
      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      closed_run = Sim.get_sim_run!(run.id)
      [entry_fill, exit_fill] = Sim.list_sim_fills(closed_run)
      total_commission = Decimal.add(entry_fill.commission, exit_fill.commission)

      refute is_nil(closed_run.realized_pnl_net)

      assert Decimal.equal?(
               closed_run.realized_pnl_net,
               Decimal.sub(closed_run.realized_pnl, total_commission)
             )

      assert Decimal.equal?(Sim.total_run_commission(closed_run), total_commission)
    end
  end

  describe "risk_at_entry" do
    test "is entry_price * multiplier * quantity" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      symbol = "RISKTEST1"
      key = contract_key(symbol)
      {_pid, run} = start_monitor(version, key)

      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      entered_run = Sim.get_sim_run!(run.id)
      refute is_nil(entered_run.risk_at_entry)
      assert Decimal.equal?(entered_run.risk_at_entry, Decimal.mult(entered_run.entry_price, 100))
    end
  end

  describe "context tracking" do
    test "captures dte_at_entry and implied_volatility (and a nil regime_label when trading_signal is unreachable)" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      symbol = "CONTEXTTEST1"
      key = contract_key(symbol)
      {_pid, run} = start_monitor(version, key)

      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      entered_run = Sim.get_sim_run!(run.id)

      # No real trading_signal node is reachable in the test env, so
      # current_regime/0 fails and regime_label stays nil — the real,
      # fail-closed "unknown" state, not a guessed default.
      assert entered_run.context["regime_label"] == nil
      assert is_integer(entered_run.context["dte_at_entry"])
      assert entered_run.context["dte_at_entry"] > 0
      assert entered_run.context["implied_volatility"] == 0.30
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

    test "\"unrestricted\" trading_hours_policy overrides a closed exchange session" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      {:ok, version} =
        Sim.update_trading_hours_settings(version, %{trading_hours_policy: "unrestricted"})

      symbol = "HOURSTEST3"
      key = contract_key(symbol)

      {pid, run} = start_monitor(version, key, exchange: closed_exchange_fixture())

      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      assert ContractMonitor.snapshot(pid).position_open? == true
      assert length(Sim.list_sim_fills(run)) == 1
    end

    test "\"extended_only\" trading_hours_policy fails closed even on an open exchange session" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      {:ok, version} =
        Sim.update_trading_hours_settings(version, %{trading_hours_policy: "extended_only"})

      symbol = "HOURSTEST4"
      key = contract_key(symbol)

      {pid, run} = start_monitor(version, key, exchange: always_open_exchange_fixture())

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

    test "fails open when :exchange is nil — hours gating is opt-in, not a trap for a member that predates it" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      symbol = "HOURSTEST4"
      key = contract_key(symbol)
      {pid, run} = start_monitor(version, key, exchange: nil)

      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      assert ContractMonitor.snapshot(pid).position_open? == true
      assert length(Sim.list_sim_fills(run)) == 1
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

    test "snapshot reports ibkr_live_subscribed?: false when the real subscribe RPC fails, without crashing the monitor" do
      # HubClient isn't started in test env (config :start_hub_client,
      # false), so the real trading_hub subscribe_symbol/3 RPC always
      # fails here — this asserts the "log and continue" precedent (see
      # IBKRLive's own moduledoc) surfaces as a readable status rather
      # than either crashing this monitor or silently claiming a live
      # subscription that doesn't exist.
      version = version_fixture(%{})
      symbol = "IBKRLIVE4"
      occ_symbol = "IBKRLIVE4_OCC"
      key = contract_key(symbol)

      {pid, _run} =
        start_monitor(version, key, pricing_backend: :ibkr_live, occ_symbol: occ_symbol)

      assert Process.alive?(pid)
      assert ContractMonitor.snapshot(pid).ibkr_live_subscribed? == false
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

    test "a Decimal-valued signal doesn't crash entry — persisted snapshot stores it as a string" do
      # Confirmed live 2026-09-15: a real trading_signal broadcast can
      # carry a Decimal (RuleEngine.evaluate/2's own type spec explicitly
      # allows Decimal.t() | number()), which crashed submit_entry/2's
      # Jason-backed entry_snapshot persistence outright
      # (Protocol.UndefinedError, Jason.Encoder not implemented for
      # Decimal) — this monitor died the instant a real entry fired.
      SignalBusTest.stub_topic("vix_last", "signals:vix_last_decimal_topic")

      version =
        version_fixture(%{
          "entry" => %{"signal" => "vix_last", "op" => "gt", "value" => 20}
        })

      symbol = "SIGNALDECIMAL1"
      key = contract_key(symbol)
      {pid, run} = start_monitor(version, key)

      Phoenix.PubSub.broadcast(
        TradingSignal.PubSub,
        "signals:vix_last_decimal_topic",
        {:signal, "vix_last_decimal_topic", Decimal.new("25.5")}
      )

      Process.sleep(30)
      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)

      assert Process.alive?(pid)
      assert ContractMonitor.snapshot(pid).position_open? == true

      [fill] = Sim.list_sim_fills(run)
      updated_run = Sim.get_sim_run!(run.id)
      assert updated_run.entry_snapshot["vix_last"] == "25.5"
      assert fill.kind == "entry"
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

  describe "force_close/2" do
    test "flattens an open position and returns :ok" do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}
        })

      symbol = "FORCECLOSE1"
      key = contract_key(symbol)
      {pid, run} = start_monitor(version, key)

      broadcast_underlying_price(symbol, 150.0)
      Process.sleep(50)
      assert ContractMonitor.snapshot(pid).position_open? == true

      assert :ok = ContractMonitor.force_close(pid, :manual)

      assert ContractMonitor.snapshot(pid).position_open? == false
      closed_run = Sim.get_sim_run!(run.id)
      assert closed_run.status == "closed"
      assert closed_run.exit_reason == "manual"
    end

    test "is a no-op on a flat monitor" do
      version = version_fixture(%{})
      key = contract_key("FORCECLOSE2")
      {pid, run} = start_monitor(version, key)

      assert :ok = ContractMonitor.force_close(pid, :manual)

      assert ContractMonitor.snapshot(pid).position_open? == false
      assert Sim.get_sim_run!(run.id).status == "open"
    end

    test "is a no-op when no snapshot has been priced yet, even with position_open?: true" do
      version = version_fixture(%{})
      key = contract_key("FORCECLOSE3")

      {:ok, run} =
        Sim.open_sim_run(version, %{
          symbol: "FORCECLOSE3",
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
           contract_key: key,
           strategy_version: version,
           direction: "long",
           quantity: 1,
           position_open?: true,
           exchange: always_open_exchange_fixture()}
        )

      assert :ok = ContractMonitor.force_close(pid, :manual)

      assert Sim.get_sim_run!(run.id).status == "open"
    end
  end
end
