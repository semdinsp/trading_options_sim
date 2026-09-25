defmodule TradingOptionsSim.EodCloserTest do
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.EodCloser
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.{ExchangeSession, ExchangeTradingHours}

  # async: false — EodCloser.run_once/0 scans TradingOptionsSim.MonitorRegistry
  # globally (every running ContractMonitor across every test), same
  # isolation concern ContractMonitorTest's own async: false already
  # documents.

  defp version_fixture(rules \\ %{}) do
    {:ok, strategy} = Sim.create_strategy(%{name: "Test Strategy"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1},
        rules: rules
      })

    version
  end

  defp contract_key(symbol) do
    {symbol, "20271231", Decimal.new("150.00"), "C"}
  end

  # `minutes_until_close` relative to right now, in UTC — deliberately
  # time-relative (not a fixed clock time) so this test is correct
  # regardless of when it actually runs. Mirrors
  # TradingLive.EodCloserTest's identical `seed_exchange_session/3`.
  defp seed_exchange_session(exchange, minutes_until_close, opts \\ []) do
    now = DateTime.utc_now()
    close_at = DateTime.add(now, minutes_until_close * 60, :second)

    attrs = %{
      name: "EOD-test-#{exchange}",
      timezone: "Etc/UTC",
      start_time: ~T[00:00:00],
      end_time: DateTime.to_time(close_at),
      days_of_week: [1, 2, 3, 4, 5, 6, 7],
      close_before_minutes: Keyword.get(opts, :close_before_minutes, 11)
    }

    {:ok, hours} =
      %ExchangeTradingHours{}
      |> ExchangeTradingHours.changeset(attrs)
      |> Repo.insert()

    {:ok, _session} =
      %ExchangeSession{}
      |> ExchangeSession.changeset(%{exchange: exchange, exchange_trading_hours_id: hours.id})
      |> Repo.insert()

    :ok
  end

  # Starts the monitor already `position_open?: true` (same pattern
  # ContractMonitorTest's own "expiry handling" describe block uses) —
  # deliberately does NOT rely on a real entry tick to open the position,
  # since that path itself goes through session_open?/1 and several of
  # this file's own tests need an open position on an exchange whose
  # session is currently closed/unmapped, which would never let a real
  # entry fire in the first place. A subsequent price tick still needs
  # to arrive once to populate last_snapshot (force-close reads it, per
  # ContractMonitor's own handle_info({:force_close_eod, reason}, ...)
  # doc) — that tick's own session_open?/1 check is irrelevant here
  # since maybe_transition/2 (position_open?: true clause) only fires on
  # a satisfied exit rule, and this fixture's version has none.
  defp start_monitor_with_open_position(exchange, symbol, opts \\ []) do
    # A never-satisfied exit rule — a nil/empty rules map would evaluate
    # vacuously true (see TradingCore.RuleEngine.evaluate/2's own doc)
    # and force this position closed on the very first price tick,
    # before EodCloser ever runs.
    version =
      version_fixture(%{
        "exit" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 999_999}
      })

    version =
      if Keyword.has_key?(opts, :overnight_hold) do
        {:ok, version} =
          Sim.update_trading_hours_settings(version, %{
            overnight_hold: Keyword.fetch!(opts, :overnight_hold)
          })

        version
      else
        version
      end

    expiry = Keyword.get(opts, :expiry, "20271231")
    key = {symbol, expiry, Decimal.new("150.00"), "C"}

    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: symbol,
        expiry: expiry,
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

    {:ok, pid} =
      start_supervised(
        {ContractMonitor,
         sim_run_id: run.id,
         contract_key: key,
         strategy_version: version,
         direction: "long",
         quantity: 1,
         exchange: exchange,
         position_open?: true}
      )

    message =
      %{type: :price, symbol: symbol, source: :ibkr, data: %{last: 150.0}}
      |> Map.put(:__struct__, TradingHub.Message)

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:#{symbol}", message)
    Process.sleep(50)

    {pid, run}
  end

  test "closes an open position when its exchange closes within the window" do
    exchange = "EOD-#{System.unique_integer([:positive])}"
    :ok = seed_exchange_session(exchange, 5)

    {pid, run} = start_monitor_with_open_position(exchange, "EODCLOSE1")
    assert ContractMonitor.snapshot(pid).position_open? == true

    :ok = EodCloser.run_once()
    Process.sleep(50)

    assert ContractMonitor.snapshot(pid).position_open? == false

    closed_run = Sim.get_sim_run!(run.id)
    assert closed_run.status == "closed"
    assert closed_run.exit_reason == "eod_flatten"
  end

  test "does not close a position when overnight_hold is set on its strategy version" do
    exchange = "EOD-#{System.unique_integer([:positive])}"
    :ok = seed_exchange_session(exchange, 5)

    {pid, run} =
      start_monitor_with_open_position(exchange, "EODHOLD1", overnight_hold: true)

    assert ContractMonitor.snapshot(pid).position_open? == true

    :ok = EodCloser.run_once()
    Process.sleep(50)

    assert ContractMonitor.snapshot(pid).position_open? == true
    assert Sim.get_sim_run!(run.id).status == "open"
  end

  # D3 (trading_live OPTIONS_PROMOTION_PLAN.md): a contract inside its
  # expiry window (<= expiry_close_dte, 1) must be flat by that day's
  # close, overnight_hold or not -- holding it would carry it into
  # expiry day.
  describe "expiry window" do
    defp et_date_plus(days) do
      DateTime.now!("America/New_York")
      |> DateTime.to_date()
      |> Date.add(days)
      |> Calendar.strftime("%Y%m%d")
    end

    test "closes an expiring contract even when overnight_hold is set" do
      exchange = "EOD-#{System.unique_integer([:positive])}"
      :ok = seed_exchange_session(exchange, 5)

      {_pid, run} =
        start_monitor_with_open_position(exchange, "EODEXP1",
          overnight_hold: true,
          expiry: et_date_plus(1)
        )

      :ok = EodCloser.run_once()
      Process.sleep(50)

      closed = Sim.get_sim_run!(run.id)
      assert closed.status == "closed"
      assert closed.exit_reason == "expiry"
    end

    test "labels an expiring contract's close \"expiry\", not eod_flatten" do
      exchange = "EOD-#{System.unique_integer([:positive])}"
      :ok = seed_exchange_session(exchange, 5)

      {_pid, run} = start_monitor_with_open_position(exchange, "EODEXP2", expiry: et_date_plus(1))

      :ok = EodCloser.run_once()
      Process.sleep(50)

      assert Sim.get_sim_run!(run.id).exit_reason == "expiry"
    end

    # Must NOT fire on healthy input: two days out is outside the window,
    # so overnight_hold still keeps the position.
    test "overnight_hold still holds a contract outside its expiry window" do
      exchange = "EOD-#{System.unique_integer([:positive])}"
      :ok = seed_exchange_session(exchange, 5)

      {pid, run} =
        start_monitor_with_open_position(exchange, "EODEXP3",
          overnight_hold: true,
          expiry: et_date_plus(2)
        )

      :ok = EodCloser.run_once()
      Process.sleep(50)

      assert ContractMonitor.snapshot(pid).position_open?
      assert Sim.get_sim_run!(run.id).status == "open"
    end
  end

  # Before 2026-09-24 a monitor flattened by EodCloser re-entered on its
  # next tick and was flattened again a minute later, repeatedly, until
  # the close: a spread-and-fees round trip each time, every day.
  describe "no new entries inside the close window" do
    defp start_flat_always_entering(exchange, symbol, opts \\ []) do
      version =
        version_fixture(%{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 0},
          "exit" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 999_999}
        })

      version =
        if Keyword.get(opts, :overnight_hold) do
          {:ok, v} = Sim.update_trading_hours_settings(version, %{overnight_hold: true})
          v
        else
          version
        end

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
           contract_key: contract_key(symbol),
           strategy_version: version,
           direction: "long",
           quantity: 1,
           exchange: exchange}
        )

      {pid, run}
    end

    defp tick(pid, symbol) do
      message =
        %{type: :price, symbol: symbol, source: :ibkr, data: %{last: 150.0}}
        |> Map.put(:__struct__, TradingHub.Message)

      Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:#{symbol}", message)
      _ = ContractMonitor.snapshot(pid)
    end

    test "a flat monitor does not enter within the close window" do
      exchange = "EOD-#{System.unique_integer([:positive])}"
      :ok = seed_exchange_session(exchange, 5)

      {pid, run} = start_flat_always_entering(exchange, "NOENTRY1")
      tick(pid, "NOENTRY1")

      refute ContractMonitor.snapshot(pid).position_open?
      assert Sim.list_sim_fills(run) == []
    end

    # Must NOT fire on healthy input: an hour before the close, entries
    # proceed as normal.
    test "a flat monitor still enters outside the close window" do
      exchange = "EOD-#{System.unique_integer([:positive])}"
      :ok = seed_exchange_session(exchange, 60)

      {pid, _run} = start_flat_always_entering(exchange, "NOENTRY2")
      tick(pid, "NOENTRY2")

      assert ContractMonitor.snapshot(pid).position_open?
    end

    test "overnight_hold versions may still enter within the close window" do
      exchange = "EOD-#{System.unique_integer([:positive])}"
      :ok = seed_exchange_session(exchange, 5)

      {pid, _run} = start_flat_always_entering(exchange, "NOENTRY3", overnight_hold: true)
      tick(pid, "NOENTRY3")

      assert ContractMonitor.snapshot(pid).position_open?
    end

    test "after an EOD flatten the monitor does not re-enter" do
      exchange = "EOD-#{System.unique_integer([:positive])}"
      :ok = seed_exchange_session(exchange, 5)

      {pid, run} = start_monitor_with_open_position(exchange, "NOENTRY4")
      :ok = EodCloser.run_once()
      _ = ContractMonitor.snapshot(pid)
      assert Sim.get_sim_run!(run.id).exit_reason == "eod_flatten"

      # The next ticks used to re-open immediately.
      tick(pid, "NOENTRY4")
      tick(pid, "NOENTRY4")

      refute ContractMonitor.snapshot(pid).position_open?
    end
  end

  test "does not close a position when its exchange closes outside the window" do
    exchange = "EOD-#{System.unique_integer([:positive])}"
    :ok = seed_exchange_session(exchange, 120)

    {pid, run} = start_monitor_with_open_position(exchange, "EODCLOSE2")
    assert ContractMonitor.snapshot(pid).position_open? == true

    :ok = EodCloser.run_once()
    Process.sleep(50)

    assert ContractMonitor.snapshot(pid).position_open? == true
    assert Sim.get_sim_run!(run.id).status == "open"
  end

  test "does not close a flat monitor" do
    version = version_fixture()
    key = contract_key("EODCLOSE3")
    exchange = "EOD-#{System.unique_integer([:positive])}"
    :ok = seed_exchange_session(exchange, 5)

    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: "EODCLOSE3",
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
         exchange: exchange}
      )

    :ok = EodCloser.run_once()
    Process.sleep(50)

    assert ContractMonitor.snapshot(pid).position_open? == false
    assert Sim.get_sim_run!(run.id).status == "open"
  end

  test "skips a monitor with an unmapped exchange" do
    {pid, run} = start_monitor_with_open_position("EOD-UNMAPPED", "EODCLOSE4")
    assert ContractMonitor.snapshot(pid).position_open? == true

    :ok = EodCloser.run_once()
    Process.sleep(50)

    assert ContractMonitor.snapshot(pid).position_open? == true
    assert Sim.get_sim_run!(run.id).status == "open"
  end

  # TradingOptionsSim.MonitorRegistry is shared with
  # TradingOptionsSim.Pricing.IBKRLive, whose own keys ({:ibkr_live,
  # occ_symbol}) are also 2-tuples — a real bug had running_monitors/0's
  # Registry.select match spec catch those too and call :snapshot on
  # them, crashing every running IBKRLive listener on each tick (it has
  # no matching handle_call clause). Confirmed live via a full test-suite
  # run before this test existed: real "no function clause matching in
  # TradingOptionsSim.Pricing.IBKRLive.handle_call/3" crashes appeared in
  # the log whenever an IBKRLive-backed ContractMonitorTest ran
  # concurrently with an EodCloser scan.
  test "does not crash a co-registered IBKRLive listener" do
    occ_symbol = "EOD-IBKR-SNAPSHOT-TEST"
    contract = %{sec_type: "OPT", expiry: "20271231", strike: 150.0, right: "C"}

    pid =
      start_supervised!(
        {TradingOptionsSim.Pricing.IBKRLive, occ_symbol: occ_symbol, contract: contract}
      )

    :ok = EodCloser.run_once()
    Process.sleep(50)

    assert Process.alive?(pid)
    assert TradingOptionsSim.Pricing.IBKRLive.whereis(occ_symbol) == pid
  end
end
