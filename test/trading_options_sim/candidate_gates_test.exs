defmodule TradingOptionsSim.CandidateGatesTest do
  # DataCase, not plain ExUnit.Case — gate G (regime_concentration) does
  # a real DB query (Sim.closed_runs_by_regime/1) for any row that
  # isn't already :not_applicable, same accepted tradeoff
  # trading_system's own CandidateGates makes (see this module's own
  # moduledoc).
  use TradingOptionsSim.DataCase, async: true

  alias TradingOptionsSim.CandidateGates

  @now ~U[2026-09-15 20:00:00Z]

  defp base_row(overrides \\ %{}) do
    Map.merge(
      %{
        strategy_version_id: Ecto.UUID.generate(),
        n_closes: 40,
        lcb95: 0.05,
        cost_margin: Decimal.new("0.10"),
        realized_pnl: Decimal.new("100.00"),
        exit_reason_histogram: %{"rule_exit" => 20, "expiry" => 20},
        excluded_count: 0,
        last_traded_on: @now,
        quarantine_trading_days: 25,
        rules: %{"entry" => %{"signal" => "run_underlying_price", "op" => "gt", "value" => 100}}
      },
      overrides
    )
  end

  describe "gate_order/0 and gate_letter/1" do
    test "every gate has a distinct single-character letter" do
      letters = CandidateGates.gate_order() |> Enum.map(&CandidateGates.gate_letter/1)
      assert length(letters) == 9
      assert length(Enum.uniq(letters)) == 9
      assert Enum.all?(letters, &(String.length(&1) == 1))
    end
  end

  describe "sample_floor (N)" do
    test "passes at exactly 30" do
      gates = CandidateGates.evaluate(base_row(%{n_closes: 30}), @now)
      assert gates.sample_floor == :pass
    end

    test "fails below 30" do
      gates = CandidateGates.evaluate(base_row(%{n_closes: 29}), @now)
      assert gates.sample_floor == :fail
    end
  end

  describe "statistical (S)" do
    test "passes when lcb95 is strictly positive" do
      gates = CandidateGates.evaluate(base_row(%{lcb95: 0.001}), @now)
      assert gates.statistical == :pass
    end

    test "fails when lcb95 is zero, negative, or nil" do
      assert CandidateGates.evaluate(base_row(%{lcb95: 0.0}), @now).statistical == :fail
      assert CandidateGates.evaluate(base_row(%{lcb95: -0.01}), @now).statistical == :fail
      assert CandidateGates.evaluate(base_row(%{lcb95: nil}), @now).statistical == :fail
    end
  end

  describe "economic (E)" do
    test "passes when cost_margin is positive" do
      gates = CandidateGates.evaluate(base_row(%{cost_margin: Decimal.new("0.01")}), @now)
      assert gates.economic == :pass
    end

    test "fails when cost_margin is zero, negative, or nil" do
      assert CandidateGates.evaluate(base_row(%{cost_margin: Decimal.new(0)}), @now).economic ==
               :fail

      assert CandidateGates.evaluate(base_row(%{cost_margin: Decimal.new("-0.01")}), @now).economic ==
               :fail

      assert CandidateGates.evaluate(base_row(%{cost_margin: nil}), @now).economic == :fail
    end
  end

  describe "dollars_agree (D)" do
    test "passes when realized_pnl is positive" do
      gates = CandidateGates.evaluate(base_row(%{realized_pnl: Decimal.new("0.01")}), @now)
      assert gates.dollars_agree == :pass
    end

    test "fails when realized_pnl is zero, negative, or nil" do
      assert CandidateGates.evaluate(base_row(%{realized_pnl: Decimal.new(0)}), @now).dollars_agree ==
               :fail

      assert CandidateGates.evaluate(base_row(%{realized_pnl: nil}), @now).dollars_agree == :fail
    end
  end

  describe "exit_logic (X)" do
    defp exit_gate(histogram),
      do: CandidateGates.evaluate(base_row(%{exit_reason_histogram: histogram}), @now).exit_logic

    test "passes when forced exits are under 70%" do
      assert exit_gate(%{"rule_exit" => 50, "expiry" => 50}) == :pass
    end

    # The healthy case: the exit rule closes nearly every trade.
    test "passes when rule exits dominate, however large" do
      assert exit_gate(%{"rule_exit" => 84, "eod_flatten" => 4}) == :pass
      assert exit_gate(%{"rule_exit" => 100}) == :pass
    end

    test "fails when one forced exit reaches 70%" do
      assert exit_gate(%{"expiry" => 70, "rule_exit" => 30}) == :fail
      assert exit_gate(%{"eod_flatten" => 9, "rule_exit" => 1}) == :fail
    end

    test "fails when forced exits together reach 70%, though none does alone" do
      assert exit_gate(%{
               "eod_flatten" => 40,
               "stop_loss" => 20,
               "take_profit" => 10,
               "rule_exit" => 30
             }) ==
               :fail
    end

    test "leaves non-trades out of the count" do
      # 6 eod of 10 real exits is 60%: passes despite 50 no-entry closes.
      assert exit_gate(%{"eod_flatten" => 6, "rule_exit" => 4, "manual_no_entry" => 50}) == :pass
      # Without the no-entries, 8 of 10 forced: fails.
      assert exit_gate(%{"eod_flatten" => 8, "rule_exit" => 2, "orphaned" => 90}) == :fail
    end

    test "fails when the only closes are non-trades" do
      assert exit_gate(%{"manual_no_entry" => 5}) == :fail
    end

    test "fails when the histogram is empty" do
      gates = CandidateGates.evaluate(base_row(%{exit_reason_histogram: %{}}), @now)
      assert gates.exit_logic == :fail
    end
  end

  describe "churn (C)" do
    test "passes when excluded ratio is under 20%" do
      gates = CandidateGates.evaluate(base_row(%{n_closes: 90, excluded_count: 10}), @now)
      assert gates.churn == :pass
    end

    test "fails when excluded ratio is at or above 20%" do
      gates = CandidateGates.evaluate(base_row(%{n_closes: 80, excluded_count: 20}), @now)
      assert gates.churn == :fail
    end

    test "fails when there are no runs at all" do
      gates = CandidateGates.evaluate(base_row(%{n_closes: 0, excluded_count: 0}), @now)
      assert gates.churn == :fail
    end
  end

  describe "recency (R)" do
    test "passes within the 3-day window" do
      last_traded = DateTime.add(@now, -3, :day)
      gates = CandidateGates.evaluate(base_row(%{last_traded_on: last_traded}), @now)
      assert gates.recency == :pass
    end

    test "fails past the 3-day window" do
      last_traded = DateTime.add(@now, -4, :day)
      gates = CandidateGates.evaluate(base_row(%{last_traded_on: last_traded}), @now)
      assert gates.recency == :fail
    end

    test "fails when never traded" do
      gates = CandidateGates.evaluate(base_row(%{last_traded_on: nil}), @now)
      assert gates.recency == :fail
    end
  end

  describe "regime_concentration (G)" do
    test "is not_applicable when the entry rule already conditions on regime" do
      row =
        base_row(%{
          rules: %{
            "entry" => %{"signal" => "regime_trend_ordinal", "op" => "gt", "value" => 0}
          }
        })

      gates = CandidateGates.evaluate(row, @now)
      assert gates.regime_concentration == :not_applicable
    end

    test "is not_computed when there is no rules map" do
      gates = CandidateGates.evaluate(Map.delete(base_row(), :rules), @now)
      assert gates.regime_concentration == :not_computed
    end
  end

  describe "quarantine_tenure (T)" do
    test "passes at exactly 20 days" do
      gates = CandidateGates.evaluate(base_row(%{quarantine_trading_days: 20}), @now)
      assert gates.quarantine_tenure == :pass
    end

    test "fails below 20 days" do
      gates = CandidateGates.evaluate(base_row(%{quarantine_trading_days: 19}), @now)
      assert gates.quarantine_tenure == :fail
    end

    test "fails (not exempt) when quarantine_trading_days is nil" do
      gates = CandidateGates.evaluate(base_row(%{quarantine_trading_days: nil}), @now)
      assert gates.quarantine_tenure == :fail
    end
  end

  describe "candidate?/1" do
    test "true when every computed gate passes" do
      gates = %{
        sample_floor: :pass,
        statistical: :pass,
        economic: :pass,
        dollars_agree: :pass,
        exit_logic: :pass,
        churn: :pass,
        recency: :pass,
        regime_concentration: :not_applicable,
        quarantine_tenure: :pass
      }

      assert CandidateGates.candidate?(gates)
    end

    test "false when any computed gate fails" do
      gates = %{
        sample_floor: :pass,
        statistical: :fail,
        economic: :pass,
        dollars_agree: :pass,
        exit_logic: :pass,
        churn: :pass,
        recency: :pass,
        regime_concentration: :not_applicable,
        quarantine_tenure: :pass
      }

      refute CandidateGates.candidate?(gates)
    end
  end

  describe "blocked_only_by_tenure?/1" do
    test "true when tenure is the only failing gate" do
      gates = %{
        sample_floor: :pass,
        statistical: :pass,
        economic: :pass,
        dollars_agree: :pass,
        exit_logic: :pass,
        churn: :pass,
        recency: :pass,
        regime_concentration: :not_applicable,
        quarantine_tenure: :fail
      }

      assert CandidateGates.blocked_only_by_tenure?(gates)
    end

    test "false when another gate also fails" do
      gates = %{
        sample_floor: :fail,
        statistical: :pass,
        economic: :pass,
        dollars_agree: :pass,
        exit_logic: :pass,
        churn: :pass,
        recency: :pass,
        regime_concentration: :not_applicable,
        quarantine_tenure: :fail
      }

      refute CandidateGates.blocked_only_by_tenure?(gates)
    end
  end

  describe "gates_failed/1" do
    test "counts only :fail, excluding :not_computed/:not_applicable" do
      gates = %{
        sample_floor: :fail,
        statistical: :fail,
        economic: :pass,
        dollars_agree: :pass,
        exit_logic: :pass,
        churn: :pass,
        recency: :pass,
        regime_concentration: :not_applicable,
        quarantine_tenure: :not_computed
      }

      assert CandidateGates.gates_failed(gates) == 2
    end
  end
end
