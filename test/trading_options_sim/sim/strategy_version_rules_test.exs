defmodule TradingOptionsSim.Sim.StrategyVersionRulesTest do
  use TradingOptionsSim.DataCase, async: true

  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.Sim.StrategyVersion

  defp create(rules) do
    {:ok, strategy} = Sim.create_strategy(%{name: "Rules #{System.unique_integer([:positive])}"})

    Sim.create_strategy_version(strategy, %{
      version: 1,
      position_sizing: %{"method" => "fixed_qty", "qty" => 1},
      rules: rules
    })
  end

  defp leaf(op, value \\ 0),
    do: %{"signal" => "run_poly_vwap_dev_bps", "op" => op, "value" => value}

  # Must not fire on healthy input: every rule shape in use today passes
  # (all 429 versions on the dev DB passed on 2026-10-07).
  test "accepts every comparison op, nested all/any/not, value_signal and empty rules" do
    for rules <- [
          %{},
          %{"entry" => %{}, "exit" => nil},
          %{"entry" => leaf("gt", 5), "exit" => leaf("lt", -5)},
          %{"entry" => leaf("gte", 1.5), "exit" => leaf("lte", 0)},
          %{"entry" => %{"signal" => "regime_trend_ordinal", "op" => "eq", "value" => 0}},
          %{
            "entry" => %{
              "all" => [
                leaf("gt", 10),
                %{
                  "any" => [
                    leaf("lt", 3),
                    %{"signal" => "definition:abc", "op" => "gt", "value" => 0.5}
                  ]
                },
                %{"not" => %{"all" => [leaf("gt", 1), leaf("gt", 2)]}}
              ]
            },
            "exit" => %{
              "signal" => "run_current_price",
              "op" => "lte",
              "value_signal" => "run_stop_loss_price"
            }
          },
          # "Hold to the EOD flatten" idiom
          %{
            "entry" => leaf("gt", 0),
            "exit" => %{"signal" => "run_underlying_price", "op" => "lt", "value" => 0}
          }
        ] do
      assert StrategyVersion.rules_errors(rules) == [], inspect(rules)
      assert {:ok, _} = create(rules)
    end
  end

  # trading_system's CG-03 used "ne" in its exit; the RuleEngine evaluates
  # unknown ops to :unknown, so that exit silently never fired.
  test "rejects ne with a hint to use not/eq" do
    assert {:error, changeset} = create(%{"exit" => leaf("ne", -1)})
    assert [{msg, _}] = Keyword.get_values(changeset.errors, :rules)
    assert msg =~ "exit: unsupported op \"ne\""
    assert msg =~ "{\"not\""
  end

  test "rejects unknown ops nested inside combinators, naming the path" do
    rules = %{"entry" => %{"all" => [leaf("gt", 1), %{"not" => leaf("gt ", 2)}]}}
    assert [msg] = StrategyVersion.rules_errors(rules)
    assert msg =~ "entry.all[1].not: unsupported op \"gt \""
  end

  test "rejects transition ops, which never fire here" do
    for op <- ~w(crosses_above crosses_below sign_flip changed) do
      assert [msg] = StrategyVersion.rules_errors(%{"entry" => leaf(op)})
      assert msg =~ "never fires in this app", op
    end
  end

  # Never stricter than the RuleEngine: it treats nil/empty nodes as true
  # at any depth, "all": [] as vacuously true, and parses numeric strings.
  test "accepts what the RuleEngine accepts: nested empty nodes, all: [], numeric strings" do
    # LifecycleReview's regime fork when the parent's entry is empty
    gate = %{"signal" => "regime_trend_ordinal", "op" => "eq", "value" => 0}
    assert {:ok, _} = create(%{"entry" => %{"all" => [%{}, gate]}})
    assert StrategyVersion.rules_errors(%{"entry" => %{"all" => [nil, gate]}}) == []
    assert StrategyVersion.rules_errors(%{"entry" => %{"all" => []}}) == []
    assert StrategyVersion.rules_errors(%{"entry" => leaf("gt", "5")}) == []
    assert StrategyVersion.rules_errors(%{"entry" => leaf("lt", "-0.5")}) == []
  end

  test "rejects leaves without a numeric value or value_signal, and malformed nodes" do
    # Decimal.new("abc") would raise inside the monitor at evaluation time
    assert [msg] = StrategyVersion.rules_errors(%{"entry" => leaf("gt", "abc")})
    assert msg =~ "needs a numeric \"value\""
    assert [_] = StrategyVersion.rules_errors(%{"entry" => leaf("gt", nil)})

    assert [_] = StrategyVersion.rules_errors(%{"entry" => %{"op" => "gt", "value" => 1}})
    # can never pass
    assert [_] = StrategyVersion.rules_errors(%{"entry" => %{"any" => []}})
    assert [_] = StrategyVersion.rules_errors(%{"entry" => %{"any" => leaf("gt")}})
    assert [_] = StrategyVersion.rules_errors(%{"entry" => %{"not" => [leaf("gt")]}})
    assert [_] = StrategyVersion.rules_errors("not a map")
  end

  test "reports every bad leaf on both sides" do
    rules = %{"entry" => %{"any" => [leaf("ne"), leaf("neq")]}, "exit" => leaf("between")}
    assert length(StrategyVersion.rules_errors(rules)) == 3
  end
end
