defmodule TradingOptionsSim.SimRunTest do
  use TradingOptionsSim.DataCase, async: true

  alias TradingOptionsSim.Sim

  defp version_fixture do
    {:ok, strategy} = Sim.create_strategy(%{name: "Test Strategy"})

    {:ok, version} =
      Sim.create_strategy_version(strategy, %{
        version: 1,
        position_sizing: %{"method" => "fixed_qty", "qty" => 1}
      })

    version
  end

  defp run_attrs do
    %{
      symbol: "AAPL",
      expiry: "20270115",
      strike: Decimal.new("150.00"),
      right: "C",
      multiplier: 100,
      direction: "long"
    }
  end

  describe "open_sim_run/2" do
    test "creates a run in open status" do
      version = version_fixture()

      assert {:ok, run} = Sim.open_sim_run(version, run_attrs())
      assert run.status == "open"
      assert run.symbol == "AAPL"
      assert Decimal.equal?(run.strike, Decimal.new("150.00"))
    end

    test "requires symbol/expiry/strike/right" do
      version = version_fixture()

      assert {:error, changeset} = Sim.open_sim_run(version, %{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.symbol
      assert "can't be blank" in errors.expiry
      assert "can't be blank" in errors.strike
      assert "can't be blank" in errors.right
    end
  end

  describe "record_entry_fill/3" do
    test "creates an entry fill and stamps the run's entry fields" do
      version = version_fixture()
      {:ok, run} = Sim.open_sim_run(version, run_attrs())

      now = DateTime.utc_now()

      assert {:ok, {fill, updated_run}} =
               Sim.record_entry_fill(
                 run,
                 %{action: "buy", quantity: 1, fill_price: Decimal.new("5.20"), filled_at: now},
                 %{entry_at: now, entry_price: Decimal.new("5.20")}
               )

      assert fill.kind == "entry"
      assert Decimal.equal?(updated_run.entry_price, Decimal.new("5.20"))
      assert updated_run.status == "open"
    end
  end

  describe "record_exit_fill/3" do
    test "creates an exit fill and closes the run" do
      version = version_fixture()
      {:ok, run} = Sim.open_sim_run(version, run_attrs())
      now = DateTime.utc_now()

      {:ok, {_fill, run}} =
        Sim.record_entry_fill(
          run,
          %{action: "buy", quantity: 1, fill_price: Decimal.new("5.20"), filled_at: now},
          %{entry_at: now, entry_price: Decimal.new("5.20")}
        )

      later = DateTime.add(now, 3600, :second)

      assert {:ok, {fill, closed_run}} =
               Sim.record_exit_fill(
                 run,
                 %{
                   action: "sell",
                   quantity: 1,
                   fill_price: Decimal.new("6.50"),
                   filled_at: later
                 },
                 %{
                   exit_at: later,
                   exit_price: Decimal.new("6.50"),
                   exit_reason: "target_hit",
                   realized_pnl: Decimal.new("130.00")
                 }
               )

      assert fill.kind == "exit"
      assert closed_run.status == "closed"
      assert Decimal.equal?(closed_run.realized_pnl, Decimal.new("130.00"))
    end
  end

  describe "list_open_sim_runs/1" do
    test "only returns open runs for the given version" do
      version = version_fixture()
      {:ok, open_run} = Sim.open_sim_run(version, run_attrs())
      {:ok, closed_run} = Sim.open_sim_run(version, run_attrs())

      now = DateTime.utc_now()

      {:ok, {_fill, closed_run}} =
        Sim.record_entry_fill(
          closed_run,
          %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: now},
          %{entry_at: now, entry_price: Decimal.new("5.00")}
        )

      {:ok, {_fill, _closed_run}} =
        Sim.record_exit_fill(
          closed_run,
          %{action: "sell", quantity: 1, fill_price: Decimal.new("4.00"), filled_at: now},
          %{
            exit_at: now,
            exit_price: Decimal.new("4.00"),
            exit_reason: "stopped_out",
            realized_pnl: Decimal.new("-100.00")
          }
        )

      open_runs = Sim.list_open_sim_runs(version)
      assert length(open_runs) == 1
      assert hd(open_runs).id == open_run.id
    end
  end

  describe "list_sim_fills/1" do
    test "returns fills in filled_at order" do
      version = version_fixture()
      {:ok, run} = Sim.open_sim_run(version, run_attrs())
      now = DateTime.utc_now()
      later = DateTime.add(now, 3600, :second)

      {:ok, {_entry_fill, run}} =
        Sim.record_entry_fill(
          run,
          %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: now},
          %{entry_at: now, entry_price: Decimal.new("5.00")}
        )

      {:ok, {_exit_fill, run}} =
        Sim.record_exit_fill(
          run,
          %{action: "sell", quantity: 1, fill_price: Decimal.new("6.00"), filled_at: later},
          %{
            exit_at: later,
            exit_price: Decimal.new("6.00"),
            exit_reason: "target_hit",
            realized_pnl: Decimal.new("100.00")
          }
        )

      fills = Sim.list_sim_fills(run)
      assert length(fills) == 2
      assert Enum.map(fills, & &1.kind) == ["entry", "exit"]
    end
  end

  describe "total_run_commission/1" do
    test "sums commission across the run's fills" do
      version = version_fixture()
      {:ok, run} = Sim.open_sim_run(version, run_attrs())
      now = DateTime.utc_now()

      {:ok, {_fill, run}} =
        Sim.record_entry_fill(
          run,
          %{
            action: "buy",
            quantity: 1,
            fill_price: Decimal.new("5.00"),
            filled_at: now,
            commission: Decimal.new("1.68")
          },
          %{entry_at: now, entry_price: Decimal.new("5.00")}
        )

      {:ok, {_fill, run}} =
        Sim.record_exit_fill(
          run,
          %{
            action: "sell",
            quantity: 1,
            fill_price: Decimal.new("6.00"),
            filled_at: now,
            commission: Decimal.new("1.68")
          },
          %{
            exit_at: now,
            exit_price: Decimal.new("6.00"),
            exit_reason: "target_hit",
            realized_pnl: Decimal.new("100.00")
          }
        )

      assert Decimal.equal?(Sim.total_run_commission(run), Decimal.new("3.36"))
    end

    test "returns nil when the run has no fills yet" do
      version = version_fixture()
      {:ok, run} = Sim.open_sim_run(version, run_attrs())

      assert Sim.total_run_commission(run) == nil
    end

    test "returns nil when any fill's commission is unknown" do
      version = version_fixture()
      {:ok, run} = Sim.open_sim_run(version, run_attrs())
      now = DateTime.utc_now()

      {:ok, {_fill, run}} =
        Sim.record_entry_fill(
          run,
          %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: now},
          %{entry_at: now, entry_price: Decimal.new("5.00")}
        )

      assert Sim.total_run_commission(run) == nil
    end

    test "works whether or not :sim_fills is already preloaded" do
      version = version_fixture()
      {:ok, run} = Sim.open_sim_run(version, run_attrs())
      now = DateTime.utc_now()

      {:ok, {_fill, run}} =
        Sim.record_entry_fill(
          run,
          %{
            action: "buy",
            quantity: 1,
            fill_price: Decimal.new("5.00"),
            filled_at: now,
            commission: Decimal.new("1.68")
          },
          %{entry_at: now, entry_price: Decimal.new("5.00")}
        )

      preloaded_run = TradingOptionsSim.Repo.preload(run, :sim_fills, force: true)

      assert Decimal.equal?(
               Sim.total_run_commission(run),
               Sim.total_run_commission(preloaded_run)
             )
    end
  end

  describe "count_fills_for_version/1" do
    test "counts every fill across every run belonging to the version" do
      version = version_fixture()
      {:ok, run1} = Sim.open_sim_run(version, run_attrs())
      {:ok, run2} = Sim.open_sim_run(version, run_attrs())
      now = DateTime.utc_now()

      {:ok, {_fill, _run1}} =
        Sim.record_entry_fill(
          run1,
          %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: now},
          %{entry_at: now, entry_price: Decimal.new("5.00")}
        )

      {:ok, {_fill, run2}} =
        Sim.record_entry_fill(
          run2,
          %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: now},
          %{entry_at: now, entry_price: Decimal.new("5.00")}
        )

      {:ok, {_fill, _run2}} =
        Sim.record_exit_fill(
          run2,
          %{action: "sell", quantity: 1, fill_price: Decimal.new("6.00"), filled_at: now},
          %{
            exit_at: now,
            exit_price: Decimal.new("6.00"),
            exit_reason: "target_hit",
            realized_pnl: Decimal.new("100.00")
          }
        )

      # run1: 1 fill (entry only), run2: 2 fills (entry + exit) = 3 total.
      assert Sim.count_fills_for_version(version) == 3
    end

    test "returns 0 when the version has no fills yet" do
      version = version_fixture()
      assert Sim.count_fills_for_version(version) == 0
    end
  end

  describe "list_recent_fills_for_version/2" do
    test "returns fills across every run for the version, most recent first, bounded by limit" do
      version = version_fixture()
      {:ok, run} = Sim.open_sim_run(version, run_attrs())
      now = DateTime.utc_now()
      later = DateTime.add(now, 3600, :second)

      {:ok, {_fill, run}} =
        Sim.record_entry_fill(
          run,
          %{action: "buy", quantity: 1, fill_price: Decimal.new("5.00"), filled_at: now},
          %{entry_at: now, entry_price: Decimal.new("5.00")}
        )

      {:ok, {_fill, _run}} =
        Sim.record_exit_fill(
          run,
          %{action: "sell", quantity: 1, fill_price: Decimal.new("6.00"), filled_at: later},
          %{
            exit_at: later,
            exit_price: Decimal.new("6.00"),
            exit_reason: "target_hit",
            realized_pnl: Decimal.new("100.00")
          }
        )

      fills = Sim.list_recent_fills_for_version(version, 1)
      assert length(fills) == 1
      assert hd(fills).kind == "exit"
      assert Sim.count_fills_for_version(version) == 2
    end
  end
end
