defmodule TradingOptionsSim.ComboMonitorTest do
  use TradingOptionsSim.DataCase, async: false

  alias TradingOptionsSim.{ComboMonitor, ContractMonitor, Sim, SimActivator}
  alias TradingOptionsSim.Sim.{SimFill, SimRun}

  @expiry "20271231"

  defp d(s), do: Decimal.new(s)

  defp version_fixture(params \\ %{}) do
    {:ok, strategy} = Sim.create_strategy(%{name: "Combo #{System.unique_integer([:positive])}"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        direction: "short",
        position_sizing: %{"method" => "fixed_qty", "qty" => 1},
        option_leg_config: %{
          "expiry_selection" => "fixed",
          "fixed_expiry" => @expiry,
          "multi_leg" => %{"structure" => "put_credit_spread", "short_offset" => 5, "width" => 5}
        },
        rules: %{
          "entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100},
          "exit" => %{"signal" => "run_underlying_price", "op" => "lt", "value" => 0}
        },
        params:
          Map.merge(
            %{
              "risk_controls" => %{
                "method" => "percent_of_entry",
                "stop_loss_percent" => 100,
                "take_profit_percent" => 50
              }
            },
            params
          )
      })

    version
  end

  # A 145/140 put credit spread on a $150 underlying.
  defp legs do
    [
      %{leg_index: 0, right: "P", side: "short", strike: d("145"), expiry: @expiry, ratio: 1},
      %{leg_index: 1, right: "P", side: "long", strike: d("140"), expiry: @expiry, ratio: 1}
    ]
  end

  defp always_open_exchange do
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
      |> Repo.insert()

    {:ok, _} =
      %TradingOptionsSim.Sim.ExchangeSession{}
      |> TradingOptionsSim.Sim.ExchangeSession.changeset(%{
        exchange: exchange,
        exchange_trading_hours_id: hours.id
      })
      |> Repo.insert()

    exchange
  end

  defp start_combo(version, symbol) do
    {:ok, run} =
      Sim.open_sim_run(version, %{
        symbol: symbol,
        expiry: @expiry,
        strike: d("145"),
        right: "P",
        direction: "short",
        structure: "put_credit_spread"
      })

    spec = %{
      id: {ComboMonitor, System.unique_integer([:positive])},
      start:
        {ComboMonitor, :start_link,
         [
           [
             strategy_version: version,
             symbol: symbol,
             sim_run_id: run.id,
             structure: "put_credit_spread",
             legs: legs(),
             exchange: always_open_exchange()
           ]
         ]},
      restart: :transient
    }

    {:ok, pid} = start_supervised(spec)
    {pid, run}
  end

  defp tick(pid, symbol, last) do
    message =
      %{type: :price, symbol: symbol, source: :ibkr, data: %{last: last}}
      |> Map.put(:__struct__, TradingHub.Message)

    Phoenix.PubSub.broadcast(TradingOptionsSim.PubSub, "prices:#{symbol}", message)
    _ = ContractMonitor.snapshot(pid)
    :ok
  end

  defp fills(run_id, kind) do
    Repo.all(
      from f in SimFill,
        where: f.sim_run_id == ^run_id and f.kind == ^kind,
        order_by: f.leg_index
    )
  end

  defp entered(run_id), do: Repo.get!(SimRun, run_id) |> Repo.preload(:legs)

  describe "entry" do
    test "sells the short leg and buys the wing together, at a net credit" do
      version = version_fixture()
      {pid, run} = start_combo(version, "CMB1")

      tick(pid, "CMB1", 150.0)

      run = entered(run.id)
      assert run.entry_at
      assert run.structure == "put_credit_spread"

      [short_fill, long_fill] = fills(run.id, "entry")
      assert {short_fill.leg_index, short_fill.action} == {0, "sell"}
      assert {long_fill.leg_index, long_fill.action} == {1, "buy"}

      # The run's entry price is the NET credit: short premium less wing.
      credit = Decimal.sub(short_fill.fill_price, long_fill.fill_price)
      assert Decimal.gt?(credit, 0)
      assert Decimal.equal?(run.entry_price, credit)

      # Legs recorded with their own fill prices.
      assert [%{side: "short"} = s, %{side: "long"} = l] = run.legs
      assert Decimal.equal?(s.entry_price, short_fill.fill_price)
      assert Decimal.equal?(l.entry_price, long_fill.fill_price)

      # R denominator = max loss = (width - credit) x 100.
      assert Decimal.equal?(
               run.risk_at_entry,
               d("5") |> Decimal.sub(credit) |> Decimal.mult(100)
             )

      assert run.context["risk_basis"] == "max_loss"

      # Stop/target on the credit, short direction: SL100 = 2x, TP50 = 0.5x.
      assert Decimal.equal?(
               Decimal.round(run.stop_loss_price, 2),
               Decimal.round(Decimal.mult(credit, 2), 2)
             )

      assert Decimal.equal?(
               Decimal.round(run.take_profit_price, 2),
               Decimal.round(Decimal.div(credit, 2), 2)
             )
    end

    test "the snapshot describes the combo, with the primary short leg as its contract" do
      version = version_fixture()
      {pid, _run} = start_combo(version, "CMB2")
      tick(pid, "CMB2", 150.0)

      snap = ContractMonitor.snapshot(pid)
      assert snap.structure == "put_credit_spread"
      assert {snap.symbol, snap.expiry, snap.right} == {"CMB2", @expiry, "P"}
      assert Decimal.equal?(snap.strike, d("145"))
      assert snap.position_open?
      assert snap.last_snapshot["run_current_price"] > 0
      assert snap.last_snapshot["run_underlying_price"] == 150.0
    end

    test "is found through the shared monitor registry" do
      version = version_fixture()
      {pid, _run} = start_combo(version, "CMB3")

      assert ComboMonitor.whereis(version.id, "CMB3") == pid
      assert ContractMonitor.monitors_for_version(version.id) == [{"CMB3", pid}]
    end
  end

  describe "exits" do
    test "takes profit when the spread decays, recording every leg's exit" do
      version = version_fixture()
      {pid, run} = start_combo(version, "CMB4")
      tick(pid, "CMB4", 150.0)

      # Far above both strikes the spread is nearly worthless.
      tick(pid, "CMB4", 400.0)

      run = entered(run.id)
      assert run.status == "closed"
      assert run.exit_reason == "take_profit"
      assert Decimal.gt?(run.realized_pnl, 0)

      assert [%{action: "buy", leg_index: 0}, %{action: "sell", leg_index: 1}] =
               fills(run.id, "exit")

      assert Enum.all?(run.legs, & &1.exit_price)

      # P&L = (entry net - exit net) x 100.
      assert Decimal.equal?(
               run.realized_pnl,
               run.entry_price |> Decimal.sub(run.exit_price) |> Decimal.mult(100)
             )
    end

    test "stops out when the spread goes against it, losing no more than its max loss" do
      version = version_fixture()
      {pid, run} = start_combo(version, "CMB5")
      tick(pid, "CMB5", 150.0)

      # Deep in the money the spread trades near its full width, past
      # the 2x-credit stop even with this far expiry's time value.
      tick(pid, "CMB5", 60.0)

      run = entered(run.id)
      assert run.exit_reason == "stop_loss"
      assert Decimal.lt?(run.realized_pnl, 0)
      refute Decimal.lt?(run.realized_pnl, Decimal.negate(run.risk_at_entry))
    end

    test "force_close flattens every leg (deactivate, EodCloser)" do
      version = version_fixture()
      {pid, run} = start_combo(version, "CMB6")
      tick(pid, "CMB6", 150.0)

      :ok = ContractMonitor.force_close(pid, :manual)

      run = entered(run.id)
      assert run.exit_reason == "manual"
      assert length(fills(run.id, "exit")) == 2
      refute ContractMonitor.snapshot(pid).position_open?
    end

    test "re-enters on a fresh run after an exit, never reusing the closed one" do
      version = version_fixture()
      {pid, run} = start_combo(version, "CMB7")
      tick(pid, "CMB7", 150.0)
      :ok = ContractMonitor.force_close(pid, :manual)

      tick(pid, "CMB7", 150.0)

      runs = Repo.all(from r in SimRun, where: r.strategy_version_id == ^version.id)
      assert length(runs) == 2
      new_run = Enum.find(runs, &(&1.id != run.id))
      assert new_run.structure == "put_credit_spread"
      assert new_run.entry_at
    end
  end

  describe "promotion" do
    test "a combo is never exported to trading_live, even with valid risk controls" do
      version = version_fixture()

      assert {:error, {:not_promotable, [reason]}} =
               TradingOptionsSim.Sim.PromotionExport.build(version.id)

      assert reason =~ "multi_leg"
    end
  end

  describe "SimActivator" do
    test "resumes an entered combo on its stored legs, and deactivate flattens it" do
      version = version_fixture()

      {:ok, pool} =
        Sim.create_target_pool(%{name: "Combo pool #{System.unique_integer([:positive])}"})

      {:ok, _} = Sim.add_target_pool_member(pool, %{symbol: "CMB8"})

      {:ok, version} =
        version
        |> Ecto.Changeset.change(target_pool_id: pool.id)
        |> Repo.update()

      {:ok, run} =
        Sim.open_sim_run(version, %{
          symbol: "CMB8",
          expiry: @expiry,
          strike: d("145"),
          right: "P",
          direction: "short",
          structure: "put_credit_spread"
        })

      leg_rows =
        Enum.map(
          legs(),
          &Map.put(&1, :entry_price, if(&1.side == "short", do: d("2.00"), else: d("1.00")))
        )

      {:ok, _} =
        Sim.record_combo_entry_fills(
          run,
          [
            %{
              action: "sell",
              quantity: 1,
              fill_price: d("2.00"),
              filled_at: DateTime.utc_now(),
              commission: d("0.65"),
              leg_index: 0
            },
            %{
              action: "buy",
              quantity: 1,
              fill_price: d("1.00"),
              filled_at: DateTime.utc_now(),
              commission: d("0.65"),
              leg_index: 1
            }
          ],
          leg_rows,
          %{entry_at: DateTime.utc_now(), entry_price: d("1.00"), risk_at_entry: d("400")}
        )

      assert {:ok, [pid], _unsubscribed} = SimActivator.activate(version)
      assert ComboMonitor.whereis(version.id, "CMB8") == pid

      snap = ContractMonitor.snapshot(pid)
      assert snap.position_open?
      assert Enum.map(snap.legs, &Decimal.to_string(&1.strike)) == ["145", "140"]

      # Idempotent: a second activate reuses the running monitor.
      assert {:ok, [^pid], _} = SimActivator.activate(version)

      # No priced tick yet, so the forced close is skipped, but the
      # monitor is stopped either way.
      tick(pid, "CMB8", 150.0)
      assert {:ok, 1} = SimActivator.deactivate(version)
      assert Repo.get!(SimRun, run.id).exit_reason == "manual"
    end
  end
end
