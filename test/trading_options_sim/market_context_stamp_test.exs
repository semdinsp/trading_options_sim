defmodule TradingOptionsSim.MarketContextStampTest do
  # The shared TradingCore.MarketContext stamp on every entry and exit
  # fill. async: false: real ContractMonitors, the application's
  # RegimeCache and MarketContextSignals singletons.
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.{ContractMonitor, MarketContextSignals, RegimeCache, Sim}
  alias TradingOptionsSim.SignalBus.Test, as: SignalBusTest

  @gamma_slug "cboe_spy_gamma_exposure_ex0dte"

  setup do
    previous = RegimeCache.current()

    on_exit(fn ->
      RegimeCache.put(previous)
      :ets.delete(MarketContextSignals, @gamma_slug)
    end)

    :ok
  end

  defp et_today,
    do: DateTime.utc_now() |> DateTime.shift_zone!("America/New_York") |> DateTime.to_date()

  defp regime(session_date) do
    %{
      label: "calm|chop",
      trend_state: :chop,
      vol_state: :calm,
      vol_state_percentile: :normal,
      vix_level: Decimal.new("16.3"),
      spy_price: Decimal.new("765.49"),
      spy_sma_20: Decimal.new("765.44"),
      spy_slope_20: Decimal.new("0.18"),
      evaluated_at: DateTime.utc_now(),
      session_date: session_date
    }
  end

  defp sync(name), do: _ = :sys.get_state(Process.whereis(name))

  describe "RegimeCache heartbeat" do
    test "a heartbeat refreshes evaluated_at and session_date and keeps the rest" do
      yesterday = Date.add(et_today(), -1)
      RegimeCache.put(regime(yesterday))
      now = DateTime.utc_now()

      send(
        Process.whereis(RegimeCache),
        {:regime_heartbeat, %{label: "calm|chop", evaluated_at: now, session_date: et_today()}}
      )

      sync(RegimeCache)

      current = RegimeCache.current()
      assert current.session_date == et_today()
      assert current.evaluated_at == now
      assert Decimal.equal?(current.vix_level, Decimal.new("16.3"))
    end
  end

  describe "MarketContextSignals" do
    test "stores a received value with its time and drops it when cleared" do
      SignalBusTest.stub_topic(@gamma_slug, "signals:definition:gamma-test")
      send(Process.whereis(MarketContextSignals), :trading_signal_connected)
      sync(MarketContextSignals)

      Phoenix.PubSub.broadcast(
        TradingSignal.PubSub,
        "signals:definition:gamma-test",
        {:signal, "definition:gamma-test", Decimal.new("-920000000")}
      )

      sync(MarketContextSignals)
      assert {value, %DateTime{}} = MarketContextSignals.values()[@gamma_slug]
      assert Decimal.equal?(value, Decimal.new("-920000000"))

      Phoenix.PubSub.broadcast(
        TradingSignal.PubSub,
        "signals:definition:gamma-test",
        {:signal_cleared, "definition:gamma-test"}
      )

      sync(MarketContextSignals)
      refute Map.has_key?(MarketContextSignals.values(), @gamma_slug)
    end
  end

  describe "stamping fills" do
    # Enter above 149, exit below 145; exchange nil skips session hours.
    defp start_round_trip(symbol) do
      {:ok, strategy} = Sim.create_strategy(%{name: "Stamp #{symbol}"})

      {:ok, version} =
        Sim.create_strategy_version(strategy, %{
          version: 1,
          position_sizing: %{"method" => "fixed_qty", "qty" => 1},
          rules: %{
            "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 149},
            "exit" => %{"signal" => "run_underlying_price", "op" => "lt", "value" => 145}
          }
        })

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

      {pid, version}
    end

    defp tick(pid, symbol, price) do
      message =
        %{type: :price, symbol: symbol, source: :ibkr, data: %{last: price}}
        |> Map.put(:__struct__, TradingHub.Message)

      Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:#{symbol}", message)
      _ = ContractMonitor.snapshot(pid)
    end

    test "entry and exit fills and the run's snapshots carry market_context" do
      RegimeCache.put(regime(et_today()))

      :ets.insert(
        MarketContextSignals,
        {@gamma_slug, {Decimal.new("-920000000"), DateTime.utc_now()}}
      )

      {pid, version} = start_round_trip("STAMP1")
      tick(pid, "STAMP1", 150.0)
      tick(pid, "STAMP1", 140.0)

      [run] = Sim.list_sim_runs("closed") |> Enum.filter(&(&1.strategy_version_id == version.id))
      fills = Sim.list_sim_fills(run)

      for context <-
            [run.entry_snapshot["market_context"], run.exit_snapshot["market_context"]] ++
              Enum.map(fills, & &1.pricing_snapshot["market_context"]) do
        assert context["market_context_version"] == 1
        assert context["regime_label"] == "calm|chop"
        assert context["regime_session_date"] == Date.to_iso8601(et_today())
        assert context["gamma_spy_ex0dte"] == "-920000000"
        assert Map.has_key?(context["as_of"], "gamma_spy_ex0dte")
        assert Map.has_key?(context["as_of"], "regime")
      end

      assert length(fills) == 2
    end

    # A label from a previous session must not be stamped as today's.
    test "a previous session's regime is omitted, signals still stamped" do
      RegimeCache.put(regime(Date.add(et_today(), -1)))

      :ets.insert(
        MarketContextSignals,
        {@gamma_slug, {Decimal.new("5000000000"), DateTime.utc_now()}}
      )

      {pid, version} = start_round_trip("STAMP2")
      tick(pid, "STAMP2", 150.0)

      [run] = Sim.list_open_sim_runs(version)
      context = run.entry_snapshot["market_context"]

      refute Map.has_key?(context, "regime_label")
      refute Map.has_key?(context, "regime_session_date")
      assert context["gamma_spy_ex0dte"] == "5000000000"
    end
  end
end
