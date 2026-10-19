defmodule TradingOptionsSim.ComboTest do
  use TradingOptionsSim.DataCase, async: true

  alias TradingOptionsSim.{Combo, ContractSelector, Sim}
  alias TradingOptionsSim.Sim.{SimRun, SimRunLeg}

  defp d(s), do: Decimal.new(s)

  defp combo_config(multi_leg) do
    %{"expiry_selection" => "dte_target", "dte_target" => 30, "multi_leg" => multi_leg}
  end

  # SPY's grid is $5 at this spot (ContractSelection.strike_increment/2).
  describe "templates/3" do
    test "a put credit spread: short put below spot, long wing below it" do
      legs =
        Combo.templates(
          "SPY",
          %{"structure" => "put_credit_spread", "short_offset" => 15, "width" => 5},
          760.3
        )

      assert [
               %{leg_index: 0, right: "P", side: "short", strike: 745.0, ratio: 1},
               %{leg_index: 1, right: "P", side: "long", strike: 740.0, ratio: 1}
             ] = legs
    end

    test "a call credit spread: short call above spot, long wing above it" do
      legs =
        Combo.templates(
          "SPY",
          %{"structure" => "call_credit_spread", "short_offset" => 15, "width" => 10},
          760.3
        )

      assert [
               %{right: "C", side: "short", strike: 775.0},
               %{right: "C", side: "long", strike: 785.0}
             ] = legs
    end

    test "an iron condor is the put vertical then the call vertical" do
      legs =
        Combo.templates(
          "SPY",
          %{"structure" => "iron_condor", "short_offset" => 20, "width" => 5},
          760.0
        )

      assert Enum.map(legs, &{&1.leg_index, &1.right, &1.side, &1.strike}) == [
               {0, "P", "short", 740.0},
               {1, "P", "long", 735.0},
               {2, "C", "short", 780.0},
               {3, "C", "long", 785.0}
             ]
    end

    test "a wing narrower than the grid is pushed out one grid step, never onto the short strike" do
      [short, long] =
        Combo.templates(
          "SPY",
          %{"structure" => "put_credit_spread", "short_offset" => 15, "width" => 1},
          760.0
        )

      assert short.strike == 745.0
      assert long.strike == 740.0
    end
  end

  describe "net_price/2 and max_loss_per_share/2" do
    defp leg(right, side, strike), do: %{right: right, side: side, strike: d(strike), ratio: 1}

    test "a credit vertical's net price is the short premium less the long" do
      legs = [leg("P", "short", "745"), leg("P", "long", "740")]
      assert Decimal.equal?(Combo.net_price(legs, [d("3.10"), d("1.90")]), d("1.20"))
    end

    test "a credit vertical loses at most its width less the credit" do
      legs = [leg("P", "short", "745"), leg("P", "long", "740")]
      assert {:ok, loss} = Combo.max_loss_per_share(legs, d("1.20"))
      assert Decimal.equal?(loss, d("3.80"))
    end

    test "an iron condor loses at most its wider side's width less the whole credit" do
      legs = [
        leg("P", "short", "740"),
        leg("P", "long", "735"),
        leg("C", "short", "780"),
        leg("C", "long", "790")
      ]

      assert {:ok, loss} = Combo.max_loss_per_share(legs, d("2.00"))
      assert Decimal.equal?(loss, d("8.00"))
    end

    test "risk_at_entry scales the max loss by multiplier and quantity" do
      legs = [leg("C", "short", "775"), leg("C", "long", "785")]
      assert {:ok, risk} = Combo.risk_at_entry(legs, d("2.50"), 100, 2)
      assert Decimal.equal?(risk, d("1500.00"))
    end

    test "a leg set with unbounded upside loss is refused" do
      assert {:error, :undefined_risk} =
               Combo.max_loss_per_share([leg("C", "short", "780")], d("2.00"))
    end
  end

  describe "config_errors/2" do
    test "a valid credit combo has no errors" do
      config = combo_config(%{"structure" => "iron_condor", "short_offset" => 20, "width" => 5})
      assert Combo.config_errors(config, "short") == []
    end

    test "rejects an unknown structure, non-positive sizes, a long direction and a missing expiry" do
      errors =
        Combo.config_errors(
          %{"multi_leg" => %{"structure" => "butterfly", "short_offset" => 0, "width" => -5}},
          "long"
        )

      assert Enum.any?(errors, &(&1 =~ "multi_leg.structure"))
      assert Enum.any?(errors, &(&1 =~ "multi_leg.short_offset"))
      assert Enum.any?(errors, &(&1 =~ "multi_leg.width"))
      assert Enum.any?(errors, &(&1 =~ "direction must be \"short\""))
      assert Enum.any?(errors, &(&1 =~ "expiry_selection"))
    end
  end

  describe "StrategyVersion validation" do
    defp create(attrs) do
      {:ok, strategy} =
        Sim.create_strategy(%{name: "Combo #{System.unique_integer([:positive])}"})

      Sim.create_strategy_version(
        strategy,
        Map.merge(%{version: 1, position_sizing: %{"method" => "fixed_qty", "qty" => 1}}, attrs)
      )
    end

    test "saves a valid combo version" do
      assert {:ok, version} =
               create(%{
                 direction: "short",
                 option_leg_config:
                   combo_config(%{
                     "structure" => "put_credit_spread",
                     "short_offset" => 15,
                     "width" => 5
                   })
               })

      assert Combo.combo?(version.option_leg_config)
    end

    test "rejects an invalid combo version" do
      assert {:error, changeset} =
               create(%{
                 direction: "long",
                 option_leg_config:
                   combo_config(%{"structure" => "put_credit_spread", "width" => 5})
               })

      messages = errors_on(changeset).option_leg_config
      assert Enum.any?(messages, &(&1 =~ "short_offset"))
      assert Enum.any?(messages, &(&1 =~ "direction"))
    end

    test "rejects an empty multi_leg map" do
      assert {:error, changeset} =
               create(%{direction: "short", option_leg_config: combo_config(%{})})

      assert errors_on(changeset).option_leg_config != []
    end
  end

  describe "ContractSelector.first_listed_combo/4" do
    @templates [
      %{leg_index: 0, right: "P", side: "short", strike: 745.0, ratio: 1},
      %{leg_index: 1, right: "P", side: "long", strike: 740.0, ratio: 1}
    ]

    test "takes the first expiry at which every leg is listed" do
      resolver = fn _sym, expiry, strike, _right ->
        if expiry == "20261120" and strike == 740.0, do: {:error, :not_found}, else: {:ok, 1}
      end

      assert {:ok, %{expiry: "20261218", legs: [short, long]}} =
               ContractSelector.first_listed_combo(
                 ["20261120", "20261218"],
                 @templates,
                 "SPY",
                 resolver
               )

      assert short.expiry == "20261218"
      assert Decimal.equal?(long.strike, d("740.00"))
    end

    test "no expiry with every leg listed is :no_listed_contract" do
      resolver = fn _, _, _, _ -> {:error, :not_found} end

      assert {:error, :no_listed_contract} =
               ContractSelector.first_listed_combo(["20261120"], @templates, "SPY", resolver)
    end

    test "an unanswered probe stops with :hub_unavailable" do
      resolver = fn _, _, _, _ -> {:error, :hub_unreachable} end

      assert {:error, :hub_unavailable} =
               ContractSelector.first_listed_combo(
                 ["20261120", "20261218"],
                 @templates,
                 "SPY",
                 resolver
               )
    end
  end

  describe "schema" do
    test "a combo run stores its legs, ordered, with leg-tagged fills" do
      {:ok, strategy} = Sim.create_strategy(%{name: "Combo schema"})

      {:ok, version} =
        Sim.create_strategy_version(strategy, %{
          version: 1,
          direction: "short",
          position_sizing: %{"method" => "fixed_qty", "qty" => 1}
        })

      {:ok, run} =
        Sim.open_sim_run(version, %{
          symbol: "SPY",
          expiry: "20261120",
          strike: d("745"),
          right: "P",
          direction: "short",
          structure: "put_credit_spread"
        })

      for {i, side, strike} <- [{1, "long", "740"}, {0, "short", "745"}] do
        {:ok, _} =
          %SimRunLeg{}
          |> SimRunLeg.changeset(%{
            sim_run_id: run.id,
            leg_index: i,
            expiry: "20261120",
            strike: d(strike),
            right: "P",
            side: side
          })
          |> Repo.insert()
      end

      run = Repo.preload(Repo.get!(SimRun, run.id), :legs)
      assert run.structure == "put_credit_spread"
      assert Enum.map(run.legs, & &1.side) == ["short", "long"]

      assert {:error, changeset} =
               %SimRunLeg{}
               |> SimRunLeg.changeset(%{
                 sim_run_id: run.id,
                 leg_index: 0,
                 expiry: "20261120",
                 strike: d("745"),
                 right: "P",
                 side: "short"
               })
               |> Repo.insert()

      assert errors_on(changeset)[:sim_run_id] || errors_on(changeset)[:leg_index]
    end

    test "rejects an unknown structure on a run" do
      changeset =
        SimRun.changeset(%SimRun{}, %{
          strategy_version_id: Ecto.UUID.generate(),
          symbol: "SPY",
          expiry: "20261120",
          strike: d("745"),
          right: "P",
          structure: "butterfly"
        })

      refute changeset.valid?
    end
  end

  describe "display labels and R basis" do
    test "legs_label/1 lists legs in order, short as - and long as +" do
      legs = [
        %{leg_index: 1, side: "long", strike: Decimal.new("140"), right: "P"},
        %{leg_index: 0, side: "short", strike: Decimal.new("145.00"), right: "P"}
      ]

      assert Combo.legs_label(legs) == "-145.00P +140P"
      assert Combo.structure_label("iron_condor") == "iron condor"
    end

    test "r_denominator/1 labels a combo version max_loss, a naked short reg_t_margin" do
      combo = %TradingOptionsSim.Sim.StrategyVersion{
        direction: "short",
        option_leg_config: %{"multi_leg" => %{"structure" => "iron_condor"}}
      }

      naked = %TradingOptionsSim.Sim.StrategyVersion{direction: "short", option_leg_config: %{}}
      long = %TradingOptionsSim.Sim.StrategyVersion{direction: "long", option_leg_config: nil}

      assert Sim.r_denominator(combo) == "max_loss"
      assert Sim.r_denominator(naked) == "reg_t_margin"
      assert Sim.r_denominator(long) == "premium_at_risk"
    end
  end
end
