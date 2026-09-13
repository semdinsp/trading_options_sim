defmodule TradingOptionsSim.ContractMonitor do
  @moduledoc """
  One GenServer per `{sim_run_id, contract_key}` — evaluates a strategy
  version's entry/exit rules against a synthetically-priced option
  contract for exactly one underlying, and records simulated fills on a
  rule transition. See `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §5.

  **Event-driven by construction, not a poll/worker loop** — reacts the
  instant a relevant tick arrives via its own local PubSub subscription
  (§4c's `PriceRelay`), the same responsiveness property
  `trading_live`'s `StrategyStockMonitor` has. See plan §5's own note on
  why this must not become a `trading_system`-style fixed-interval tick
  loop.

  NOT one monitor per strategy — matching `StrategyStockMonitor`'s
  "isolate blast radius" rationale: one contract's tick storm or a slow
  pricing lookup never delays another contract's evaluation, and a
  crash only restarts that one monitor.

  ## v1 scope

  Single-leg long/short only (no multi-leg — plan §7). Pricing is
  synthetic (`TradingOptionsSim.Pricing.BlackScholes`, plan §5a v1) — no
  live options tick feed is assumed. Entry/exit rules are evaluated via
  `TradingCore.RuleEngine.evaluate/2` against a snapshot built from the
  current theoretical price/greeks plus a synthetic `run_current_price`
  key (matching the `run_` naming convention `TradingCore.RuleEngine`'s
  own moduledoc documents for caller-supplied, non-catalog values).

  ## Expiry handling (plan §5b)

  Tracks DTE (days to expiry, computed from `expiry`'s wire-format
  `"YYYYMMDD"` string) and force-closes with `exit_reason: "expiry"` at
  a configurable cutoff — a new lifecycle event with no stock
  equivalent, since `StrategyStockMonitor` never has to reason about a
  position's own instrument ceasing to exist.
  """

  use GenServer
  require Logger

  alias TradingCore.RuleEngine
  alias TradingOptionsSim.Pricing.BlackScholes
  alias TradingOptionsSim.Sim

  # How many days before expiry to force-close a still-open position,
  # to approximate avoiding assignment/exercise mechanics this simulator
  # doesn't model (plan §5b).
  @default_expiry_close_dte 1

  # Flat implied-vol assumption for v1's Black-Scholes pricer — a real
  # vol surface is explicitly out of scope (plan §5a v1). Overridable
  # per-monitor via :implied_volatility in start_link/1's opts.
  @default_implied_volatility 0.30

  @default_risk_free_rate 0.05

  defstruct [
    :sim_run_id,
    :contract_key,
    :strategy_version,
    :symbol,
    :expiry,
    :strike,
    :right,
    :multiplier,
    :direction,
    :quantity,
    :implied_volatility,
    :risk_free_rate,
    :expiry_close_dte,
    :entry_rule,
    :exit_rule,
    position_open?: false,
    last_snapshot: %{}
  ]

  @type t :: %__MODULE__{}

  @type contract_key :: {String.t(), String.t(), Decimal.t(), String.t()}

  @doc """
  Builds the `{run_id, contract_key_string}` Registry key — `contract_key`
  is serialized as a stable string per plan §1
  (`"AAPL:20270115:150.00:C"`).
  """
  @spec registry_key(String.t(), contract_key()) :: {String.t(), String.t()}
  def registry_key(run_id, {symbol, expiry, strike, right}) do
    {run_id, "#{symbol}:#{expiry}:#{Decimal.to_string(strike)}:#{right}"}
  end

  def start_link(opts) do
    sim_run_id = Keyword.fetch!(opts, :sim_run_id)
    contract_key = Keyword.fetch!(opts, :contract_key)

    GenServer.start_link(__MODULE__, opts,
      name:
        {:via, Registry,
         {TradingOptionsSim.MonitorRegistry, registry_key(sim_run_id, contract_key)}}
    )
  end

  @doc "Looks up the running monitor for `{sim_run_id, contract_key}`, if any."
  @spec whereis(String.t(), contract_key()) :: pid() | nil
  def whereis(sim_run_id, contract_key) do
    case Registry.lookup(
           TradingOptionsSim.MonitorRegistry,
           registry_key(sim_run_id, contract_key)
         ) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc "A dashboard-facing read of this monitor's current price/greeks/position state."
  @spec snapshot(pid()) :: map()
  def snapshot(pid) do
    GenServer.call(pid, :snapshot)
  end

  @impl true
  def init(opts) do
    sim_run_id = Keyword.fetch!(opts, :sim_run_id)
    {symbol, expiry, strike, right} = Keyword.fetch!(opts, :contract_key)
    strategy_version = Keyword.fetch!(opts, :strategy_version)
    direction = Keyword.get(opts, :direction, "long")
    quantity = Keyword.get(opts, :quantity, 1)
    multiplier = Keyword.get(opts, :multiplier, 100)

    Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, "prices:#{symbol}")

    rules = strategy_version.rules || %{}

    state = %__MODULE__{
      sim_run_id: sim_run_id,
      contract_key: {symbol, expiry, strike, right},
      strategy_version: strategy_version,
      symbol: symbol,
      expiry: expiry,
      strike: strike,
      right: right,
      multiplier: multiplier,
      direction: direction,
      quantity: quantity,
      implied_volatility: Keyword.get(opts, :implied_volatility, @default_implied_volatility),
      risk_free_rate: Keyword.get(opts, :risk_free_rate, @default_risk_free_rate),
      expiry_close_dte: Keyword.get(opts, :expiry_close_dte, @default_expiry_close_dte),
      entry_rule: Map.get(rules, "entry"),
      exit_rule: Map.get(rules, "exit"),
      position_open?: Keyword.get(opts, :position_open?, false)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    reply = %{
      symbol: state.symbol,
      expiry: state.expiry,
      strike: state.strike,
      right: state.right,
      direction: state.direction,
      position_open?: state.position_open?,
      last_snapshot: state.last_snapshot
    }

    {:reply, reply, state}
  end

  # A %TradingHub.Message{type: :price} broadcast from PriceRelay —
  # recognized structurally (see IbPortfolio.Message's own moduledoc for
  # why this app has no compile-time TradingHub dependency).
  @impl true
  def handle_info(%{__struct__: TradingHub.Message, type: :price, data: data}, state) do
    case underlying_price(data) do
      nil -> {:noreply, state}
      spot -> {:noreply, evaluate(state, spot)}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp underlying_price(%{last: last}) when is_number(last), do: last

  defp underlying_price(%{bid: bid, ask: ask}) when is_number(bid) and is_number(ask),
    do: (bid + ask) / 2

  defp underlying_price(_data), do: nil

  defp evaluate(state, spot) do
    dte = days_to_expiry(state.expiry)

    cond do
      dte <= 0 and state.position_open? ->
        force_close_expiry(state, spot, dte)

      dte <= 0 ->
        state

      true ->
        priced = price_contract(state, spot, dte)
        snapshot = build_snapshot(priced, spot)

        state
        |> Map.put(:last_snapshot, snapshot)
        |> maybe_transition(snapshot)
    end
  end

  defp price_contract(state, spot, dte) do
    BlackScholes.compute(%{
      spot: spot,
      strike: Decimal.to_float(state.strike),
      time_to_expiry_years: dte / 365.0,
      risk_free_rate: state.risk_free_rate,
      volatility: state.implied_volatility,
      right: state.right
    })
  end

  defp build_snapshot(priced, spot) do
    %{
      "run_current_price" => priced.price,
      "run_underlying_price" => spot,
      "run_delta" => priced.delta,
      "run_gamma" => priced.gamma,
      "run_theta" => priced.theta,
      "run_vega" => priced.vega
    }
  end

  defp maybe_transition(%{position_open?: false} = state, snapshot) do
    if RuleEngine.evaluate(state.entry_rule, snapshot) do
      submit_entry(state, snapshot)
    else
      state
    end
  end

  defp maybe_transition(%{position_open?: true} = state, snapshot) do
    if RuleEngine.evaluate(state.exit_rule, snapshot) do
      submit_exit(state, snapshot, "rule_exit")
    else
      state
    end
  end

  defp submit_entry(state, snapshot) do
    price = fill_price(snapshot["run_current_price"])
    now = DateTime.utc_now()
    action = if state.direction == "short", do: "sell", else: "buy"

    run = Sim.get_sim_run!(state.sim_run_id)

    case Sim.record_entry_fill(
           run,
           %{action: action, quantity: state.quantity, fill_price: price, filled_at: now},
           %{entry_at: now, entry_price: price, entry_snapshot: snapshot}
         ) do
      {:ok, {_fill, _run}} ->
        Logger.info(
          "ContractMonitor: #{state.symbol} #{state.expiry} #{Decimal.to_string(state.strike)}#{state.right} entered at #{Decimal.to_string(price)}"
        )

        %{state | position_open?: true}

      {:error, reason} ->
        Logger.error("ContractMonitor: #{state.symbol} entry fill failed: #{inspect(reason)}")
        state
    end
  end

  defp submit_exit(state, snapshot, exit_reason) do
    price = fill_price(snapshot["run_current_price"])
    now = DateTime.utc_now()
    action = if state.direction == "short", do: "buy", else: "sell"

    run = Sim.get_sim_run!(state.sim_run_id)
    realized_pnl = realized_pnl(run, price, state)

    case Sim.record_exit_fill(
           run,
           %{action: action, quantity: state.quantity, fill_price: price, filled_at: now},
           %{
             exit_at: now,
             exit_price: price,
             exit_reason: exit_reason,
             realized_pnl: realized_pnl,
             exit_snapshot: snapshot
           }
         ) do
      {:ok, {_fill, _run}} ->
        Logger.info(
          "ContractMonitor: #{state.symbol} #{state.expiry} #{Decimal.to_string(state.strike)}#{state.right} exited at #{Decimal.to_string(price)} (#{exit_reason})"
        )

        %{state | position_open?: false}

      {:error, reason} ->
        Logger.error("ContractMonitor: #{state.symbol} exit fill failed: #{inspect(reason)}")
        state
    end
  end

  # BlackScholes.compute/1 returns a raw float — round to cent precision
  # rather than storing floating-point noise (e.g. 5.1999999999999998) as
  # a fill price. Decimal.from_float/1 itself is exact (preserves every
  # digit of the float's own decimal representation); the precision loss
  # this guards against is upstream, in the float arithmetic itself.
  defp fill_price(price) when is_float(price) do
    price |> Decimal.from_float() |> Decimal.round(2)
  end

  defp realized_pnl(run, exit_price, state) do
    entry_price = run.entry_price || Decimal.new(0)

    diff =
      if state.direction == "short",
        do: Decimal.sub(entry_price, exit_price),
        else: Decimal.sub(exit_price, entry_price)

    diff |> Decimal.mult(state.quantity) |> Decimal.mult(state.multiplier)
  end

  defp force_close_expiry(state, spot, dte) do
    intrinsic = BlackScholes.price_at_expiry(spot, Decimal.to_float(state.strike), state.right)
    snapshot = %{"run_current_price" => intrinsic, "run_underlying_price" => spot, "dte" => dte}
    submit_exit(state, snapshot, "expiry")
  end

  # "YYYYMMDD" wire-format string, per tws_api's own convention (plan §1)
  # — parses without any Date/Calendar library dependency this app
  # otherwise has no need for.
  defp days_to_expiry(expiry) when is_binary(expiry) do
    <<y::binary-size(4), m::binary-size(2), d::binary-size(2)>> = expiry
    expiry_date = Date.new!(String.to_integer(y), String.to_integer(m), String.to_integer(d))
    Date.diff(expiry_date, Date.utc_today())
  end
end
