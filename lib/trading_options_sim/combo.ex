defmodule TradingOptionsSim.Combo do
  @moduledoc """
  Multi-leg combos: credit verticals and iron condors. Pure functions
  only (config validation, leg templates, net price, max loss); the hub
  lookups that turn templates into listed contracts live in
  `TradingOptionsSim.ContractSelector.resolve_combo/3`.

  ## Config

  A combo version keeps its expiry choice where a single-leg version
  does (`option_leg_config`'s `"expiry_selection"` plus `"dte_target"`
  or `"fixed_expiry"`) and adds `option_leg_config["multi_leg"]`:

      %{"structure" => "put_credit_spread", "short_offset" => 15, "width" => 5}

    * `"structure"`: one of `structures/0`.
    * `"short_offset"`: dollars from spot to each SHORT strike, always
      positive and always out of the money (a put short at
      spot - offset, a call short at spot + offset).
    * `"width"`: dollars from each short strike out to its long wing.

  Strikes are rounded to the symbol's grid
  (`TradingCore.Options.ContractSelection.strike_increment/2`), and a
  wing is never closer than one grid step to its short strike.

  ## Prices and risk

  A combo is one `SimRun`. Its `entry_price`/`exit_price` are the NET
  price per share: sum over legs of (+price for a short leg, -price for
  a long one) x ratio. For a credit structure that is the credit
  received, positive, and the run's `direction` is `"short"`: P&L is
  (entry net - exit net) x multiplier x quantity, the same formula a
  single short option uses.

  `risk_at_entry` is the structure's maximum loss
  (`max_loss_per_share/2` x multiplier x quantity), which for a
  defined-risk spread is also its Reg-T margin. That keeps R and capital
  on the same basis as a naked short
  (`Sim.compute_short_risk_at_entry/6`): net P&L per dollar of capital.
  """

  alias TradingCore.Options.ContractSelection

  @structures ~w(put_credit_spread call_credit_spread iron_condor)

  @type template :: %{
          leg_index: non_neg_integer(),
          right: String.t(),
          side: String.t(),
          strike: float(),
          ratio: pos_integer()
        }

  @doc "The supported structure names."
  @spec structures() :: [String.t()]
  def structures, do: @structures

  @doc "True when a version's `option_leg_config` describes a combo."
  @spec combo?(map() | nil) :: boolean()
  def combo?(%{"multi_leg" => %{} = multi_leg}) when map_size(multi_leg) > 0, do: true
  def combo?(_config), do: false

  @doc """
  Validation messages for a combo `option_leg_config` (empty when it is
  valid). `direction` is the version's: every structure here is sold
  for a credit, so it must be `"short"`.
  """
  @spec config_errors(map(), String.t() | nil) :: [String.t()]
  def config_errors(%{"multi_leg" => multi_leg} = config, direction) do
    structure_errors(multi_leg) ++
      positive_number_errors(multi_leg, "short_offset") ++
      positive_number_errors(multi_leg, "width") ++
      expiry_errors(config) ++
      direction_errors(direction)
  end

  def config_errors(_config, _direction), do: []

  defp structure_errors(%{"structure" => s}) when s in @structures, do: []

  defp structure_errors(multi_leg),
    do: [
      "multi_leg.structure must be one of #{Enum.join(@structures, ", ")}, " <>
        "got #{inspect(Map.get(multi_leg, "structure"))}"
    ]

  defp positive_number_errors(multi_leg, key) do
    case Map.get(multi_leg, key) do
      n when is_number(n) and n > 0 -> []
      other -> ["multi_leg.#{key} must be a positive number of dollars, got #{inspect(other)}"]
    end
  end

  # Same expiry fields a single-leg version uses; ContractSelection is
  # the one place that turns them into candidates.
  defp expiry_errors(config) do
    case ContractSelection.expiry_candidates(config, Date.utc_today()) do
      {:ok, _} ->
        []

      {:error, _} ->
        [
          "a multi_leg combo needs expiry_selection \"dte_target\" (with dte_target) " <>
            "or a fixed_expiry"
        ]
    end
  end

  defp direction_errors("short"), do: []

  defp direction_errors(direction),
    do: [
      "a multi_leg credit structure is sold for a credit, so direction must be \"short\", " <>
        "got #{inspect(direction)}"
    ]

  @doc """
  The legs for `multi_leg` at `spot`, strikes on `symbol`'s grid, in a
  fixed order (puts before calls, short before long), which is also
  their `leg_index`.
  """
  @spec templates(String.t(), map(), number()) :: [template()]
  def templates(symbol, %{"structure" => structure} = multi_leg, spot) do
    increment = ContractSelection.strike_increment(symbol, spot)
    offset = multi_leg["short_offset"]
    width = multi_leg["width"]

    sides =
      case structure do
        "put_credit_spread" -> [:put]
        "call_credit_spread" -> [:call]
        "iron_condor" -> [:put, :call]
      end

    sides
    |> Enum.flat_map(&vertical(&1, spot, offset, width, increment))
    |> Enum.with_index(fn leg, i -> Map.put(leg, :leg_index, i) end)
  end

  defp vertical(:put, spot, offset, width, increment) do
    short = round_to_grid(spot - offset, increment)
    long = min(round_to_grid(short - width, increment), short - increment)
    [leg("P", "short", short), leg("P", "long", long)]
  end

  defp vertical(:call, spot, offset, width, increment) do
    short = round_to_grid(spot + offset, increment)
    long = max(round_to_grid(short + width, increment), short + increment)
    [leg("C", "short", short), leg("C", "long", long)]
  end

  defp leg(right, side, strike),
    do: %{right: right, side: side, strike: Float.round(strike * 1.0, 2), ratio: 1}

  defp round_to_grid(value, increment), do: Float.round(value / increment) * increment

  @doc """
  The combo's net price per share from each leg's price: + for a short
  leg (premium received), - for a long one (premium paid), times its
  ratio. Positive means a net credit.
  """
  @spec net_price([%{side: String.t(), ratio: pos_integer()}], [Decimal.t()]) :: Decimal.t()
  def net_price(legs, prices) do
    legs
    |> Enum.zip(prices)
    |> Enum.reduce(Decimal.new(0), fn {leg, price}, acc ->
      signed = Decimal.mult(price, leg.ratio)

      case leg.side do
        "short" -> Decimal.add(acc, signed)
        "long" -> Decimal.sub(acc, signed)
      end
    end)
  end

  @doc """
  The most the combo can lose per share at expiry, given the net
  `credit` received at entry: the minimum of credit + expiry payoff over
  every underlying price, sign-flipped. The payoff is piecewise linear
  with kinks only at strikes, so evaluating at 0, each strike and beyond
  the highest strike finds the minimum exactly.

  Returns `{:error, :undefined_risk}` when a loss grows without bound
  above the highest strike (more short calls than long), which no
  structure in `structures/0` can produce but a malformed leg set
  could.
  """
  @spec max_loss_per_share([map()], Decimal.t()) :: {:ok, Decimal.t()} | {:error, :undefined_risk}
  def max_loss_per_share(legs, credit) do
    strikes = Enum.map(legs, &to_decimal(&1.strike))
    top = Enum.max(strikes)
    beyond = Decimal.add(top, 1)

    if Decimal.lt?(pnl_at(legs, credit, Decimal.add(top, 2)), pnl_at(legs, credit, beyond)) do
      {:error, :undefined_risk}
    else
      worst =
        [Decimal.new(0), beyond | strikes]
        |> Enum.map(&pnl_at(legs, credit, &1))
        |> Enum.min(Decimal)

      {:ok, Decimal.max(Decimal.negate(worst), 0)}
    end
  end

  @doc """
  `risk_at_entry` for a combo: `max_loss_per_share/2` x multiplier x
  quantity. See the moduledoc for why this is the R denominator.
  """
  @spec risk_at_entry([map()], Decimal.t(), integer(), integer()) ::
          {:ok, Decimal.t()} | {:error, :undefined_risk}
  def risk_at_entry(legs, credit, multiplier, quantity) do
    with {:ok, per_share} <- max_loss_per_share(legs, credit) do
      {:ok, per_share |> Decimal.mult(multiplier) |> Decimal.mult(quantity)}
    end
  end

  # credit + sum of each leg's expiry value at underlying price s (a
  # long leg is worth its intrinsic value, a short one costs it).
  defp pnl_at(legs, credit, s) do
    Enum.reduce(legs, credit, fn leg, acc ->
      value = Decimal.mult(intrinsic(leg.right, to_decimal(leg.strike), s), leg.ratio)

      case leg.side do
        "long" -> Decimal.add(acc, value)
        "short" -> Decimal.sub(acc, value)
      end
    end)
  end

  defp intrinsic("C", strike, s), do: Decimal.max(Decimal.sub(s, strike), 0)
  defp intrinsic("P", strike, s), do: Decimal.max(Decimal.sub(strike, s), 0)

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)

  @doc """
  The primary short leg, whose strike/right a combo `SimRun` stores in
  its own (NOT NULL) strike/right columns: the first short leg.
  """
  @spec primary_leg([map()]) :: map()
  def primary_leg(legs), do: Enum.find(legs, &(&1.side == "short"))
end
