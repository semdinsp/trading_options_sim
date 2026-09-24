defmodule TradingOptionsSim.Sim.TradeCost do
  @moduledoc """
  What one `SimRun` actually cost, in dollars: the numbers an operator
  (or someone repricing a trade by hand) needs next to the per-share
  quote the simulator records.

  Option prices are quoted **per share**, and one contract covers
  `multiplier` shares (100 for US equity options), so:

      cost to buy = entry price × multiplier × contracts
      proceeds    = exit price  × multiplier × contracts

  For a **long** option the cost to buy is paid in full up front with
  nothing on margin, so it is also the capital the trade ties up and the
  most it can lose. That is `capital`, and `return_pct` is net P&L over
  it. A **short** option *receives* that premium instead and needs
  margin this simulator doesn't model, so `capital`/`return_pct` are
  `nil` for a short rather than a number that looks right and isn't.

  Costs are shown two ways, because they are two different things:

    * `fees` -- the commissions recorded on the fills (already netted
      out of `net_pnl`).
    * `spread_paid` -- how far each fill crossed from the quote mid
      (`fill_slippage` in the fill's pricing snapshot) × multiplier ×
      contracts. Already inside the fill prices, so already inside
      `gross_pnl`; shown so it's visible rather than hidden in the price.
      `nil` when no fill was priced against a two-sided quote (a
      model-priced fill records a slippage of "0", which means unknown).

  Pure: works on a run with its `sim_fills` loaded (or a fill list
  passed alongside), no queries.
  """

  alias TradingOptionsSim.Sim.SimRun

  @type t :: %{
          contracts: non_neg_integer(),
          cost_to_buy: Decimal.t() | nil,
          proceeds: Decimal.t() | nil,
          capital: Decimal.t() | nil,
          gross_pnl: Decimal.t() | nil,
          fees: Decimal.t() | nil,
          spread_paid: Decimal.t() | nil,
          net_pnl: Decimal.t() | nil,
          return_pct: Decimal.t() | nil,
          hold_minutes: non_neg_integer() | nil
        }

  @spec summary(SimRun.t(), [map()] | nil) :: t()
  def summary(%SimRun{} = run, fills \\ nil) do
    fills = fills || loaded_fills(run)
    contracts = contracts(fills)
    multiplier = Decimal.new(run.multiplier || 100)
    per_contract = &Decimal.mult(Decimal.mult(&1, multiplier), contracts)

    cost_to_buy = run.entry_price && per_contract.(run.entry_price)
    fees = fees(fills)
    net = net_pnl(run, fees)
    capital = if run.direction != "short", do: cost_to_buy

    %{
      contracts: contracts,
      cost_to_buy: cost_to_buy && Decimal.round(cost_to_buy, 2),
      proceeds: run.exit_price && Decimal.round(per_contract.(run.exit_price), 2),
      capital: capital && Decimal.round(capital, 2),
      gross_pnl: run.realized_pnl && Decimal.round(run.realized_pnl, 2),
      fees: fees && Decimal.round(fees, 2),
      spread_paid: spread_paid(fills, per_contract),
      net_pnl: net && Decimal.round(net, 2),
      return_pct: return_pct(net, capital),
      hold_minutes: hold_minutes(run)
    }
  end

  defp loaded_fills(%SimRun{sim_fills: fills}) when is_list(fills), do: fills
  defp loaded_fills(_run), do: []

  # From the entry fill; 1 when there is none yet (every version today
  # sizes at a fixed 1 contract).
  defp contracts(fills) do
    case Enum.find(fills, &(&1.kind == "entry")) do
      %{quantity: q} when is_integer(q) and q > 0 -> q
      _ -> 1
    end
  end

  defp fees([]), do: nil

  defp fees(fills) do
    if Enum.any?(fills, &is_nil(&1.commission)),
      do: nil,
      else: Enum.reduce(fills, Decimal.new(0), &Decimal.add(&2, &1.commission))
  end

  defp net_pnl(%{realized_pnl_net: %Decimal{} = net}, _fees), do: net

  defp net_pnl(%{realized_pnl: %Decimal{} = gross}, %Decimal{} = fees),
    do: Decimal.sub(gross, fees)

  defp net_pnl(_run, _fees), do: nil

  defp spread_paid(fills, per_contract) do
    # Only fills priced against a real quote. A model-priced fill records
    # fill_slippage "0" because it had no book to cross, which is
    # "unknown", not "free".
    fills
    |> Enum.map(&(&1.pricing_snapshot || %{}))
    |> Enum.flat_map(fn
      %{"fill_basis" => "quote", "fill_slippage" => s} when is_binary(s) -> [Decimal.new(s)]
      _ -> []
    end)
    |> case do
      [] ->
        nil

      slippages ->
        slippages
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
        |> per_contract.()
        |> Decimal.round(2)
    end
  end

  defp return_pct(%Decimal{} = net, %Decimal{} = capital) do
    if Decimal.gt?(capital, 0),
      do: net |> Decimal.div(capital) |> Decimal.mult(100) |> Decimal.round(1)
  end

  defp return_pct(_net, _capital), do: nil

  defp hold_minutes(%{entry_at: %DateTime{} = a, exit_at: %DateTime{} = b}),
    do: div(DateTime.diff(b, a, :second), 60)

  defp hold_minutes(_run), do: nil
end
