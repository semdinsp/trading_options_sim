defmodule TradingOptionsSim.EntryWindowTest do
  # Covers the two entry-side gates at either end of the session: the
  # configurable delay after the open (entry_delay_minutes) and the
  # after-close block. async: false for the same reason
  # EodCloserTest is: real ContractMonitors under the shared registry.
  use TradingOptionsSim.DataCase, async: false

  import Ecto.Query

  alias TradingOptionsSim.ContractMonitor
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.{ExchangeSession, ExchangeTradingHours, StrategyVersion}

  @always_enter %{
    "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 0},
    "exit" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 999_999}
  }

  defp version_fixture(attrs \\ %{}) do
    {:ok, strategy} = Sim.create_strategy(%{name: "Entry Window"})

    {:ok, version} =
      Sim.create_strategy_version(
        strategy,
        Map.merge(
          %{
            version: 1,
            position_sizing: %{"method" => "fixed_qty", "qty" => 1},
            rules: @always_enter
          },
          attrs
        )
      )

    version
  end

  # A session that opened `opened_minutes_ago` and closes
  # `closes_in_minutes` from now (negative = already closed), relative to
  # the real clock so the tests hold whenever they run. It uses a
  # fixed-offset zone where it is currently about midday, so the window
  # never wraps past local midnight, and a non-US market so a US holiday
  # can't close it.
  defp seed_session(exchange, opened_minutes_ago, closes_in_minutes) do
    now = DateTime.utc_now()
    tz = midday_zone(now)
    local = fn dt -> dt |> DateTime.shift_zone!(tz) |> DateTime.to_time() end

    {:ok, hours} =
      %ExchangeTradingHours{}
      |> ExchangeTradingHours.changeset(%{
        name: "EW-#{exchange}",
        timezone: tz,
        start_time: local.(DateTime.add(now, -opened_minutes_ago * 60, :second)),
        end_time: local.(DateTime.add(now, closes_in_minutes * 60, :second)),
        days_of_week: [1, 2, 3, 4, 5, 6, 7],
        close_before_minutes: 11,
        market: "TEST"
      })
      |> Repo.insert()

    {:ok, _} =
      %ExchangeSession{}
      |> ExchangeSession.changeset(%{exchange: exchange, exchange_trading_hours_id: hours.id})
      |> Repo.insert()

    :ok
  end

  # "Etc/GMT-K" is UTC+K (the sign is inverted by POSIX convention).
  defp midday_zone(now) do
    case 12 - now.hour do
      0 -> "Etc/UTC"
      k when k > 0 -> "Etc/GMT-#{k}"
      k -> "Etc/GMT+#{-k}"
    end
  end

  defp start_flat_monitor(version, exchange, symbol) do
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
         exchange: exchange}
      )

    pid
  end

  defp tick(pid, symbol) do
    message =
      %{type: :price, symbol: symbol, source: :ibkr, data: %{last: 150.0}}
      |> Map.put(:__struct__, TradingHub.Message)

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:#{symbol}", message)
    _ = ContractMonitor.snapshot(pid)
  end

  defp exchange, do: "EW-#{System.unique_integer([:positive])}"

  describe "entry_delay_elapsed?/2" do
    test "no delay is always elapsed" do
      assert ContractMonitor.entry_delay_elapsed?(
               %{entry_delay_minutes: 0, exchange: "ANY"},
               DateTime.utc_now()
             )
    end

    test "a nil exchange is never delayed" do
      assert ContractMonitor.entry_delay_elapsed?(
               %{entry_delay_minutes: 5, exchange: nil},
               DateTime.utc_now()
             )
    end

    test "an unmapped exchange blocks while a delay is set" do
      refute ContractMonitor.entry_delay_elapsed?(
               %{entry_delay_minutes: 5, exchange: exchange()},
               DateTime.utc_now()
             )
    end

    test "is false inside the delay and true once it has passed" do
      ex = exchange()
      :ok = seed_session(ex, 3, 60)

      refute ContractMonitor.entry_delay_elapsed?(
               %{entry_delay_minutes: 5, exchange: ex},
               DateTime.utc_now()
             )

      assert ContractMonitor.entry_delay_elapsed?(
               %{entry_delay_minutes: 2, exchange: ex},
               DateTime.utc_now()
             )
    end
  end

  describe "entry delay on a live monitor" do
    test "a monitor inside its delay does not enter" do
      ex = exchange()
      :ok = seed_session(ex, 3, 60)
      version = version_fixture(%{params: %{"entry_delay_minutes" => 5}})
      pid = start_flat_monitor(version, ex, "DELAY1")

      tick(pid, "DELAY1")

      snap = ContractMonitor.snapshot(pid)
      refute snap.position_open?
      assert snap.entry_delay_active?
    end

    # Must not fire on healthy input: past the delay, entries proceed.
    test "a monitor past its delay enters" do
      ex = exchange()
      :ok = seed_session(ex, 3, 60)
      version = version_fixture(%{params: %{"entry_delay_minutes" => 2}})
      pid = start_flat_monitor(version, ex, "DELAY2")

      tick(pid, "DELAY2")

      assert ContractMonitor.snapshot(pid).position_open?
    end

    test "with no delay configured a monitor enters straight after the open" do
      ex = exchange()
      :ok = seed_session(ex, 1, 60)
      pid = start_flat_monitor(version_fixture(), ex, "DELAY3")

      tick(pid, "DELAY3")

      assert ContractMonitor.snapshot(pid).position_open?
    end
  end

  describe "app-wide default delay" do
    setup do
      previous = Application.get_env(:trading_options_sim, :default_entry_delay_minutes)
      Application.put_env(:trading_options_sim, :default_entry_delay_minutes, 5)

      on_exit(fn ->
        Application.put_env(:trading_options_sim, :default_entry_delay_minutes, previous)
      end)
    end

    test "a version without its own setting uses the app default" do
      ex = exchange()
      :ok = seed_session(ex, 3, 60)
      pid = start_flat_monitor(version_fixture(), ex, "DEFAULT1")

      tick(pid, "DEFAULT1")

      snap = ContractMonitor.snapshot(pid)
      assert snap.entry_delay_minutes == 5
      refute snap.position_open?
    end

    test "params entry_delay_minutes 0 overrides the default" do
      ex = exchange()
      :ok = seed_session(ex, 3, 60)
      version = version_fixture(%{params: %{"entry_delay_minutes" => 0}})
      pid = start_flat_monitor(version, ex, "DEFAULT2")

      tick(pid, "DEFAULT2")

      assert ContractMonitor.snapshot(pid).position_open?
    end
  end

  describe "no entries after today's close" do
    # "unrestricted" skips the session-hours check, so only the close
    # guard stands between it and an after-close entry -- the gap the
    # 2026-09-30 20:00:00 UTC QQQ entries went through.
    test "an unrestricted, non-overnight version does not enter after the close" do
      ex = exchange()
      :ok = seed_session(ex, 120, -5)
      version = version_fixture()

      {:ok, version} =
        Sim.update_trading_hours_settings(version, %{trading_hours_policy: "unrestricted"})

      pid = start_flat_monitor(version, ex, "AFTERCLOSE1")
      tick(pid, "AFTERCLOSE1")

      refute ContractMonitor.snapshot(pid).position_open?
    end

    test "an overnight_hold version is not held to the close guard" do
      ex = exchange()
      :ok = seed_session(ex, 120, -5)
      version = version_fixture()

      {:ok, version} =
        Sim.update_trading_hours_settings(version, %{
          trading_hours_policy: "unrestricted",
          overnight_hold: true
        })

      pid = start_flat_monitor(version, ex, "AFTERCLOSE2")
      tick(pid, "AFTERCLOSE2")

      assert ContractMonitor.snapshot(pid).position_open?
    end
  end

  describe "operator override precedence (EntryDelay.effective/1)" do
    alias TradingOptionsSim.EntryDelay

    setup do
      previous = Application.get_env(:trading_options_sim, :default_entry_delay_minutes)
      Application.put_env(:trading_options_sim, :default_entry_delay_minutes, 5)

      on_exit(fn ->
        Application.put_env(:trading_options_sim, :default_entry_delay_minutes, previous)
      end)
    end

    test "the override wins over the version param and the default" do
      v = %{entry_delay_minutes: 7, params: %{"entry_delay_minutes" => 3}}
      assert EntryDelay.effective(v) == {7, :override}
    end

    test "an override of 0 means no delay, not 'no override'" do
      v = %{entry_delay_minutes: 0, params: %{"entry_delay_minutes" => 3}}
      assert EntryDelay.effective(v) == {0, :override}
    end

    test "a nil override falls through to the version param" do
      v = %{entry_delay_minutes: nil, params: %{"entry_delay_minutes" => 3}}
      assert EntryDelay.effective(v) == {3, :version}
    end

    test "with neither, the app default applies" do
      assert EntryDelay.effective(%{entry_delay_minutes: nil, params: %{}}) == {5, :default}
      assert EntryDelay.effective(%{entry_delay_minutes: nil, params: nil}) == {5, :default}
    end

    test "the promotion export ships the effective value and its source" do
      version =
        version_fixture(%{params: %{"entry_delay_minutes" => 3, "risk_controls" => risk()}})

      {:ok, version} = Sim.set_entry_delay_override(version, 9)

      {:ok, export} = TradingOptionsSim.Sim.PromotionExport.build(version.id)
      assert export["entry_delay_minutes"] == 9
      assert export["entry_delay_source"] == "override"
      assert export["schema_version"] == 1
    end
  end

  describe "operator override reaches a running monitor without a restart" do
    test "lifting the delay lets a monitor that was waiting enter" do
      ex = exchange()
      :ok = seed_session(ex, 3, 60)
      version = version_fixture(%{params: %{"entry_delay_minutes" => 5}})
      pid = start_flat_monitor(version, ex, "LIVE1")

      tick(pid, "LIVE1")
      assert ContractMonitor.snapshot(pid).entry_delay_active?
      refute ContractMonitor.snapshot(pid).position_open?

      {:ok, _} = Sim.set_entry_delay_override(version, 0)
      tick(pid, "LIVE1")

      snap = ContractMonitor.snapshot(pid)
      assert snap.entry_delay_minutes == 0
      refute snap.entry_delay_active?
      assert snap.position_open?
    end

    test "setting a delay blocks entries, and clearing it falls back to the version param" do
      ex = exchange()
      :ok = seed_session(ex, 3, 60)
      version = version_fixture(%{params: %{"entry_delay_minutes" => 2}})
      pid = start_flat_monitor(version, ex, "LIVE2")

      {:ok, version} = Sim.set_entry_delay_override(version, 30)
      tick(pid, "LIVE2")

      snap = ContractMonitor.snapshot(pid)
      assert snap.entry_delay_minutes == 30
      assert snap.entry_delay_active?
      refute snap.position_open?

      {:ok, _} = Sim.set_entry_delay_override(version, nil)
      tick(pid, "LIVE2")

      snap = ContractMonitor.snapshot(pid)
      assert snap.entry_delay_minutes == 2
      assert snap.position_open?
    end

    # Exits, stops and forced closes never read the delay.
    test "an exit still fires while the delay is active" do
      ex = exchange()
      :ok = seed_session(ex, 3, 60)

      version =
        version_fixture(%{
          params: %{"entry_delay_minutes" => 0},
          rules: %{
            "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 0},
            "exit" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 0}
          }
        })

      pid = start_flat_monitor(version, ex, "LIVE3")
      tick(pid, "LIVE3")
      assert ContractMonitor.snapshot(pid).position_open?

      {:ok, _} = Sim.set_entry_delay_override(version, 30)
      tick(pid, "LIVE3")

      snap = ContractMonitor.snapshot(pid)
      assert snap.entry_delay_active?
      refute snap.position_open?

      [run] =
        Repo.all(
          from r in TradingOptionsSim.Sim.SimRun,
            where: r.strategy_version_id == ^version.id and r.status == "closed"
        )

      assert run.exit_reason == "rule_exit"
    end
  end

  describe "operator override validation" do
    test "rejects a negative or non-integer override and broadcasts nothing" do
      version = version_fixture()

      Phoenix.PubSub.subscribe(
        TradingOptionsSim.PubSub,
        TradingOptionsSim.EntryDelay.topic(version.id)
      )

      assert {:error, changeset} = Sim.set_entry_delay_override(version, -1)
      assert changeset.errors[:entry_delay_minutes]
      assert {:error, _} = Sim.set_entry_delay_override(version, "abc")
      assert {:error, _} = Sim.set_entry_delay_override(version, "-3")
      refute_received {:entry_delay_minutes_updated, _}
      assert Repo.reload!(version).entry_delay_minutes == nil
    end

    test "accepts form strings, trims them, and blank clears the override" do
      version = version_fixture()
      assert {:ok, %{entry_delay_minutes: 7}} = Sim.set_entry_delay_override(version, " 7 ")
      assert {:ok, %{entry_delay_minutes: nil}} = Sim.set_entry_delay_override(version, "")
    end

    test "the database rejects a negative value written around the changeset" do
      version = version_fixture()

      assert_raise Postgrex.Error, ~r/entry_delay_minutes_non_negative/, fn ->
        Repo.update_all(
          from(v in StrategyVersion, where: v.id == ^version.id),
          set: [entry_delay_minutes: -1]
        )
      end
    end
  end

  defp risk,
    do: %{"method" => "percent_of_entry", "stop_loss_percent" => 10, "take_profit_percent" => 20}

  describe "params validation" do
    test "accepts a non-negative integer entry_delay_minutes" do
      assert StrategyVersion.params_errors(%{"entry_delay_minutes" => 5}) == []
      assert StrategyVersion.params_errors(%{"entry_delay_minutes" => 0}) == []
    end

    test "rejects a negative or non-integer entry_delay_minutes" do
      assert StrategyVersion.params_errors(%{"entry_delay_minutes" => -1}) != []
      assert StrategyVersion.params_errors(%{"entry_delay_minutes" => "5"}) != []
    end
  end
end
