defmodule TradingOptionsSim.ComboMonitor do
  @moduledoc """
  One GenServer per `{strategy_version_id, underlying}` for a multi-leg
  combo version (a credit vertical or an iron condor, see
  `TradingOptionsSim.Combo`): prices every leg on each underlying tick,
  evaluates the version's rules ONCE against the combo as a whole, and
  enters or exits every leg together.

  ## The combo as one instrument

  The rule snapshot describes the combo, not a leg. `run_current_price`
  is its NET price per share (+ short legs, - long legs: the credit, for
  a credit structure), and `run_delta`/`run_gamma`/`run_theta`/`run_vega`
  are the same signed sums of the legs' greeks. `run_bid`/`run_ask` are
  the net prices the combo could be sold/bought at when every leg has a
  real two-sided quote (sell = short bids - long asks, buy = short asks -
  long bids), and absent otherwise. Underlying, regime, Polygon and
  `trading_signal` keys are exactly what `ContractMonitor` supplies, so
  any rule a single-leg version can use works here.

  The version's `direction` is `"short"` (enforced by
  `StrategyVersion`): selling the combo collects the credit, buying it
  back pays the exit net, and P&L = (entry net - exit net) x multiplier
  x quantity, the single-short formula. `params["risk_controls"]` levels
  are set on the net credit with that same short direction (a 200% stop
  fires when buying the combo back would cost 3x the credit, a 50%
  target when it costs half). `params["exit_strategy"]` (ratchet /
  trailing) is not applied to combos.

  `risk_at_entry` is the structure's maximum loss
  (`Combo.risk_at_entry/4`), so R is net P&L per dollar of capital at
  risk, the same basis as a naked short.

  ## Fills

  Each leg fills on its own quote with `ContractMonitor`'s rules (sell
  the bid / buy the ask side of mid by the worked fraction, the full
  touch for a forced exit, the model price without a quote). A leg with
  no price at all skips the whole fill: a combo is never half-entered or
  half-exited. One `SimFill` per leg (tagged `leg_index`) and the leg
  rows are written in one transaction
  (`Sim.record_combo_entry_fills/4`, `Sim.record_combo_exit_fills/4`).
  An entry whose net is not a positive credit is refused, since it can
  only mean the legs were mispriced.

  ## Shared with ContractMonitor

  Registered in `MonitorRegistry` under `{strategy_version_id,
  "SYMBOL:combo"}`, and it answers `:snapshot`, `{:force_close, reason}`,
  `{:update_sim_run_id, id}` and `{:force_close_eod, reason}` with the
  same shapes. So `EodCloser`, `SimActivator.deactivate/1` and the
  version page treat it like any monitor, and the snapshot's
  `strike`/`right` are the primary short leg, matching the run's own
  columns. Hours, entry delay, confirmation, cooldown, min hold, the
  expiry window and the IBKR staleness gate all use `ContractMonitor`'s
  own functions. With `:ibkr_live` pricing, a stale or missing tick on
  ANY leg skips the evaluation, the same fail-closed rule.
  """

  use GenServer
  require Logger

  alias TradingCore.RuleEngine
  alias TradingOptionsSim.{Combo, ContractMonitor, Sim}
  alias TradingOptionsSim.Pricing.{BlackScholes, IBKRLive}

  @default_implied_volatility 0.30
  @default_risk_free_rate 0.05

  defstruct [
    :sim_run_id,
    :strategy_version,
    :symbol,
    :expiry,
    :strike,
    :right,
    :structure,
    :legs,
    :multiplier,
    :direction,
    :quantity,
    :implied_volatility,
    :risk_free_rate,
    :expiry_close_dte,
    :worked_spread_fraction,
    :entry_rule,
    :exit_rule,
    :exchange,
    pricing_backend: :black_scholes,
    ibkr_live_subscribed?: true,
    position_open?: false,
    entered_at: nil,
    min_hold_seconds: nil,
    entry_delay_minutes: 0,
    entry_confirm_seconds: 0,
    reentry_cooldown_seconds: 0,
    entry_true_since: nil,
    last_exit_at: nil,
    last_snapshot: %{},
    # Per-leg pricing behind last_snapshot, in leg order; what a forced
    # close fills against.
    last_leg_prices: [],
    evaluated_at: nil,
    option_tick_at: nil,
    quote_at: nil,
    unpriced_warned?: false,
    stale_warned?: false,
    stop_loss_price: nil,
    take_profit_price: nil,
    entry_price: nil,
    exit_state: %{},
    signal_names: [],
    canonical_names: %{},
    last_signal_values: %{}
  ]

  @doc "The `MonitorRegistry` key: one combo monitor per version and underlying."
  @spec registry_key(String.t(), String.t()) :: {String.t(), String.t()}
  def registry_key(strategy_version_id, symbol), do: {strategy_version_id, "#{symbol}:combo"}

  @doc "The running combo monitor for `strategy_version_id` on `symbol`, if any."
  @spec whereis(String.t(), String.t()) :: pid() | nil
  def whereis(strategy_version_id, symbol) do
    case Registry.lookup(
           TradingOptionsSim.MonitorRegistry,
           registry_key(strategy_version_id, symbol)
         ) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Options: `:strategy_version`, `:symbol`, `:sim_run_id`, `:structure`,
  `:legs` (maps with `leg_index`, `right`, `side`, `strike` (Decimal),
  `expiry`, `ratio`, and `occ_symbol` under `:ibkr_live`), `:exchange`,
  `:pricing_backend`, and the resume fields `ContractMonitor` takes
  (`:position_open?`, `:entered_at`, `:stop_loss_price`,
  `:take_profit_price`, `:entry_price`).
  """
  def start_link(opts) do
    version = Keyword.fetch!(opts, :strategy_version)
    symbol = Keyword.fetch!(opts, :symbol)

    GenServer.start_link(__MODULE__, opts,
      name:
        {:via, Registry, {TradingOptionsSim.MonitorRegistry, registry_key(version.id, symbol)}}
    )
  end

  @impl true
  def init(opts) do
    version = Keyword.fetch!(opts, :strategy_version)
    symbol = Keyword.fetch!(opts, :symbol)
    legs = opts |> Keyword.fetch!(:legs) |> Enum.sort_by(& &1.leg_index)
    pricing_backend = Keyword.get(opts, :pricing_backend, :black_scholes)

    if pricing_backend == :ibkr_live and Enum.any?(legs, &is_nil(&1[:occ_symbol])) do
      raise ArgumentError, "every leg needs an :occ_symbol when :pricing_backend is :ibkr_live"
    end

    primary = Combo.primary_leg(legs)

    Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, "prices:#{symbol}")

    Phoenix.PubSub.subscribe(
      TradingOptionsSim.PubSub,
      TradingOptionsSim.EntryDelay.topic(version.id)
    )

    rules = version.rules || %{}
    entry_rule = Map.get(rules, "entry")
    exit_rule = Map.get(rules, "exit")

    signal_names =
      (RuleEngine.signal_names(entry_rule) ++ RuleEngine.signal_names(exit_rule)) |> Enum.uniq()

    Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, "trading_signal:connected")

    state = %__MODULE__{
      sim_run_id: Keyword.fetch!(opts, :sim_run_id),
      strategy_version: version,
      symbol: symbol,
      expiry: primary.expiry,
      strike: primary.strike,
      right: primary.right,
      structure: Keyword.fetch!(opts, :structure),
      legs: legs,
      multiplier: Keyword.get(opts, :multiplier, 100),
      direction: "short",
      quantity: Keyword.get(opts, :quantity, 1),
      implied_volatility: Keyword.get(opts, :implied_volatility, @default_implied_volatility),
      risk_free_rate: Keyword.get(opts, :risk_free_rate, @default_risk_free_rate),
      expiry_close_dte:
        Keyword.get(
          opts,
          :expiry_close_dte,
          ContractMonitor.execution_defaults().expiry_close_dte
        ),
      worked_spread_fraction:
        opts
        |> Keyword.get(
          :worked_spread_fraction,
          ContractMonitor.execution_defaults().worked_spread_fraction
        )
        |> to_string()
        |> Decimal.new(),
      entry_rule: entry_rule,
      exit_rule: exit_rule,
      exchange: Keyword.get(opts, :exchange),
      pricing_backend: pricing_backend,
      ibkr_live_subscribed?: pricing_backend != :ibkr_live,
      position_open?: Keyword.get(opts, :position_open?, false),
      entered_at: Keyword.get(opts, :entered_at),
      stop_loss_price: Keyword.get(opts, :stop_loss_price),
      take_profit_price: Keyword.get(opts, :take_profit_price),
      entry_price: Keyword.get(opts, :entry_price),
      min_hold_seconds: ContractMonitor.min_hold_seconds(version),
      entry_delay_minutes: TradingOptionsSim.EntryDelay.minutes(version),
      entry_confirm_seconds: ContractMonitor.param_seconds(version, "entry_confirm_seconds"),
      reentry_cooldown_seconds:
        ContractMonitor.param_seconds(version, "reentry_cooldown_seconds"),
      last_exit_at: ContractMonitor.seed_last_exit_at(version, symbol),
      signal_names: signal_names,
      canonical_names: ContractMonitor.subscribe_to_signals(signal_names)
    }

    {:ok, state, {:continue, :start_ibkr_live}}
  end

  # Not in init/1, for the DynamicSupervisor deadlock ContractMonitor's
  # own handle_continue/2 documents.
  @impl true
  def handle_continue(:start_ibkr_live, %{pricing_backend: :ibkr_live} = state) do
    subscribed? =
      Enum.map(state.legs, fn leg ->
        ContractMonitor.start_ibkr_live(
          leg.occ_symbol,
          state.symbol,
          leg.expiry,
          leg.strike,
          leg.right
        )
      end)
      |> Enum.all?()

    {:noreply, %{state | ibkr_live_subscribed?: subscribed?}}
  end

  def handle_continue(:start_ibkr_live, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{pricing_backend: :ibkr_live, legs: legs}) do
    Enum.each(legs, fn leg ->
      case IBKRLive.whereis(leg.occ_symbol) do
        nil -> :ok
        pid -> IBKRLive.detach(pid)
      end
    end)
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call(:snapshot, _from, state) do
    reply = %{
      symbol: state.symbol,
      expiry: state.expiry,
      strike: state.strike,
      right: state.right,
      structure: state.structure,
      legs: state.legs,
      direction: state.direction,
      exchange: state.exchange,
      position_open?: state.position_open?,
      entered_at: state.entered_at,
      min_hold_seconds: state.min_hold_seconds,
      entry_delay_minutes: state.entry_delay_minutes,
      entry_delay_active?: not ContractMonitor.entry_delay_elapsed?(state, DateTime.utc_now()),
      expiry_close_dte: state.expiry_close_dte,
      ibkr_live_subscribed?: state.ibkr_live_subscribed?,
      last_snapshot: state.last_snapshot,
      evaluated_at: state.evaluated_at,
      option_tick_at: state.option_tick_at,
      quote_at: state.quote_at,
      max_tick_age_ms: ContractMonitor.max_tick_age_ms()
    }

    {:reply, reply, state}
  end

  def handle_call({:force_close, reason}, _from, state),
    do: {:reply, :ok, do_force_close(state, reason)}

  def handle_call({:update_sim_run_id, _id}, _from, %{position_open?: true} = state) do
    Logger.warning(
      "ComboMonitor: #{state.symbol} ignored update_sim_run_id/2 while a position is open"
    )

    {:reply, :ok, state}
  end

  def handle_call({:update_sim_run_id, id}, _from, state),
    do: {:reply, :ok, %{state | sim_run_id: id}}

  @impl true
  def handle_info(%{__struct__: TradingHub.Message, type: :price, data: data}, state) do
    case ContractMonitor.underlying_price(data) do
      nil -> {:noreply, state}
      spot -> {:noreply, evaluate(state, spot)}
    end
  end

  def handle_info({:signal, canonical_name, value}, state) do
    name = Map.get(state.canonical_names, canonical_name, canonical_name)
    {:noreply, put_in(state.last_signal_values[name], value)}
  end

  def handle_info({:signal_cleared, canonical_name}, state) do
    name = Map.get(state.canonical_names, canonical_name, canonical_name)
    {:noreply, %{state | last_signal_values: Map.delete(state.last_signal_values, name)}}
  end

  def handle_info(:trading_signal_connected, state) do
    canonical_names = ContractMonitor.subscribe_to_signals(state.signal_names)
    {:noreply, %{state | canonical_names: Map.merge(state.canonical_names, canonical_names)}}
  end

  def handle_info({:force_close_eod, reason}, state),
    do: {:noreply, do_force_close(state, reason)}

  def handle_info({:entry_delay_minutes_updated, minutes}, state)
      when is_integer(minutes) and minutes >= 0,
      do: {:noreply, %{state | entry_delay_minutes: minutes}}

  def handle_info(_other, state), do: {:noreply, state}

  # --- evaluation -----------------------------------------------------------

  defp evaluate(state, spot) do
    dte = ContractMonitor.days_to_expiry(state.expiry)

    cond do
      dte <= 0 and state.position_open? ->
        force_close_expiry(state, spot)

      dte <= 0 ->
        state

      true ->
        case price_legs(state, spot, dte) do
          {:ok, leg_prices, state} ->
            snapshot = combo_snapshot(state, leg_prices, spot)

            %{state | last_snapshot: snapshot, last_leg_prices: leg_prices}
            |> Map.put(:evaluated_at, DateTime.utc_now())
            |> maybe_transition_before_expiry(snapshot, dte)

          {:skip, state} ->
            state
        end
    end
  end

  # Each leg as %{price, delta, gamma, theta (per day), vega, iv, bid, ask},
  # floats, bid/ask nil without a real two-sided quote.
  defp price_legs(%{pricing_backend: :black_scholes} = state, spot, dte) do
    prices =
      Enum.map(state.legs, fn leg ->
        p =
          BlackScholes.compute(%{
            spot: spot,
            strike: Decimal.to_float(leg.strike),
            time_to_expiry_years: dte / 365.0,
            risk_free_rate: state.risk_free_rate,
            volatility: state.implied_volatility,
            right: leg.right
          })

        %{
          price: p.price,
          delta: p.delta,
          gamma: p.gamma,
          theta: p.theta / 365,
          vega: p.vega,
          iv: state.implied_volatility,
          underlying: spot,
          bid: nil,
          ask: nil
        }
      end)

    {:ok, prices, state}
  end

  defp price_legs(%{pricing_backend: :ibkr_live} = state, spot, _dte) do
    now = DateTime.utc_now()
    ticks = Enum.map(state.legs, &IBKRLive.latest(&1.occ_symbol))

    cond do
      Enum.any?(ticks, &match?({:error, _}, &1)) ->
        {:skip, state}

      not Enum.all?(ticks, fn {:ok, tick} -> ContractMonitor.fresh?(tick, now) end) ->
        {:skip, warn_stale(state)}

      true ->
        ticks = Enum.map(ticks, fn {:ok, tick} -> ContractMonitor.drop_stale_quote(tick, now) end)

        prices =
          Enum.map(ticks, fn tick ->
            quote = ContractMonitor.quote_values(Map.get(tick, :quote))

            %{
              price: tick.price,
              delta: tick.delta,
              gamma: tick.gamma,
              theta: tick.theta,
              vega: tick.vega,
              iv: tick.implied_vol,
              underlying: tick.underlying_price || spot,
              bid: quote["run_bid"],
              ask: quote["run_ask"]
            }
          end)

        state = %{
          state
          | stale_warned?: false,
            option_tick_at: ticks |> Enum.map(& &1[:at]) |> oldest(),
            quote_at: ticks |> Enum.map(&ContractMonitor.quote_received_at/1) |> oldest()
        }

        {:ok, prices, state}
    end
  end

  defp oldest(times) do
    if Enum.all?(times, &match?(%DateTime{}, &1)), do: Enum.min(times, DateTime)
  end

  defp warn_stale(%{stale_warned?: true} = state), do: state

  defp warn_stale(state) do
    Logger.warning(
      "ComboMonitor: #{state.symbol} #{state.structure} IBKR option data is stale on a leg; " <>
        "not evaluating until every leg refreshes"
    )

    %{state | stale_warned?: true}
  end

  # The rule snapshot for the combo as one instrument; see the moduledoc.
  defp combo_snapshot(state, leg_prices, spot) do
    net = fn key -> signed_sum(state.legs, leg_prices, key) end
    net_price = net.(:price)
    underlying = leg_prices |> hd() |> Map.get(:underlying, spot)

    primary_iv =
      state.legs
      |> Enum.zip(leg_prices)
      |> Enum.find_value(fn {l, p} -> l.side == "short" && p.iv end)

    ContractMonitor.signal_values(state)
    |> Map.merge(%{
      "run_current_price" => net_price,
      "run_underlying_price" => underlying,
      "run_delta" => net.(:delta),
      "run_gamma" => net.(:gamma),
      "run_theta" => net.(:theta),
      "run_vega" => net.(:vega),
      "run_implied_vol" => primary_iv
    })
    |> Map.merge(net_quote(state.legs, leg_prices))
    |> then(fn snap ->
      if is_number(net_price) and net_price > 0 do
        Map.merge(
          snap,
          ContractMonitor.derived_values(
            net_price,
            underlying,
            snap["run_delta"],
            snap["run_theta"],
            nil
          )
        )
      else
        snap
      end
    end)
    |> Map.merge(ContractMonitor.regime_values())
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # + for a short leg, - for a long one, times its ratio; nil when any
  # leg lacks the value, so a rule on it fails closed.
  defp signed_sum(legs, leg_prices, key) do
    legs
    |> Enum.zip(leg_prices)
    |> Enum.reduce_while(0.0, fn {leg, p}, acc ->
      case Map.get(p, key) do
        v when is_number(v) -> {:cont, acc + sign(leg) * v * leg.ratio}
        _ -> {:halt, nil}
      end
    end)
  end

  defp sign(%{side: "short"}), do: 1
  defp sign(%{side: "long"}), do: -1

  # Net bid = what selling the combo would collect (short legs at their
  # bids, long legs at their asks); net ask = what buying it back would
  # cost. Only when every leg has a real quote and the net market is a
  # proper credit.
  defp net_quote(legs, leg_prices) do
    pairs = Enum.zip(legs, leg_prices)

    if Enum.all?(pairs, fn {_l, p} -> is_number(p.bid) and is_number(p.ask) end) do
      bid =
        Enum.reduce(pairs, 0.0, fn {l, p}, acc ->
          acc + sign(l) * l.ratio * if(l.side == "short", do: p.bid, else: p.ask)
        end)

      ask =
        Enum.reduce(pairs, 0.0, fn {l, p}, acc ->
          acc + sign(l) * l.ratio * if(l.side == "short", do: p.ask, else: p.bid)
        end)

      if bid > 0 and ask > bid, do: %{"run_bid" => bid, "run_ask" => ask}, else: %{}
    else
      %{}
    end
  end

  # Same expiry window as ContractMonitor: no new entry inside it.
  defp maybe_transition_before_expiry(%{position_open?: false} = state, _snapshot, dte)
       when is_integer(state.expiry_close_dte) and dte <= state.expiry_close_dte,
       do: state

  defp maybe_transition_before_expiry(state, snapshot, _dte),
    do: maybe_transition(state, snapshot)

  defp maybe_transition(%{position_open?: false} = state, snapshot) do
    now = DateTime.utc_now()

    state =
      if RuleEngine.evaluate(state.entry_rule, snapshot),
        do: %{state | entry_true_since: state.entry_true_since || now},
        else: %{state | entry_true_since: nil}

    if state.entry_true_since != nil and ContractMonitor.session_open?(state) and
         not ContractMonitor.closing_soon?(state) and
         ContractMonitor.entry_delay_elapsed?(state, now) and
         ContractMonitor.entry_confirmed?(state, now) and ContractMonitor.cooled_down?(state, now) do
      submit(state, snapshot, state.last_leg_prices, :entry, "entry")
    else
      state
    end
  end

  defp maybe_transition(%{position_open?: true} = state, snapshot) do
    case risk_exit(state, snapshot) do
      nil ->
        if ContractMonitor.min_hold_elapsed?(state) and
             RuleEngine.evaluate(state.exit_rule, snapshot) and
             ContractMonitor.session_open?(state) do
          submit(state, snapshot, state.last_leg_prices, :exit, "rule_exit")
        else
          state
        end

      reason ->
        if ContractMonitor.session_open?(state),
          do: submit(state, snapshot, state.last_leg_prices, :exit, reason),
          else: state
    end
  end

  # Stops and targets on the combo's net price, short direction.
  defp risk_exit(%{stop_loss_price: nil, take_profit_price: nil}, _snapshot), do: nil

  defp risk_exit(state, snapshot) do
    case decimal(snapshot["run_current_price"]) do
      nil ->
        nil

      price ->
        cond do
          TradingCore.RiskControls.hit_stop_loss?(state.stop_loss_price, price, "short") ->
            "stop_loss"

          TradingCore.RiskControls.hit_take_profit?(state.take_profit_price, price, "short") ->
            "take_profit"

          true ->
            nil
        end
    end
  end

  # --- forced closes -------------------------------------------------------

  defp do_force_close(%{position_open?: false} = state, _reason), do: state

  defp do_force_close(%{last_leg_prices: []} = state, _reason) do
    Logger.warning("ComboMonitor: #{state.symbol} force-close skipped — no priced snapshot yet")
    state
  end

  defp do_force_close(state, reason),
    do: submit(state, state.last_snapshot, state.last_leg_prices, :exit, to_string(reason))

  # Expired: every leg at its intrinsic value, no quotes.
  defp force_close_expiry(state, spot) do
    leg_prices =
      Enum.map(state.legs, fn leg ->
        %{
          price: BlackScholes.price_at_expiry(spot, Decimal.to_float(leg.strike), leg.right),
          bid: nil,
          ask: nil
        }
      end)

    snapshot = %{
      "run_current_price" => signed_sum(state.legs, leg_prices, :price),
      "run_underlying_price" => spot
    }

    submit(state, snapshot, leg_prices, :exit, "expiry")
  end

  # --- fills ----------------------------------------------------------------

  # Selling the combo sells its short legs and buys its long ones;
  # buying it back does the reverse.
  defp leg_action(%{side: "short"}, :entry), do: "sell"
  defp leg_action(%{side: "long"}, :entry), do: "buy"
  defp leg_action(%{side: "short"}, :exit), do: "buy"
  defp leg_action(%{side: "long"}, :exit), do: "sell"

  defp submit(state, snapshot, leg_prices, kind, reason) do
    fills =
      state.legs
      |> Enum.zip(leg_prices)
      |> Enum.map(fn {leg, p} -> leg_fill(state, leg, p, leg_action(leg, kind), reason) end)

    if Enum.any?(fills, &(&1 == :no_price)) do
      skip_unpriced(state, reason)
    else
      case kind do
        :entry -> record_entry(state, snapshot, fills)
        :exit -> record_exit(state, snapshot, fills, reason)
      end
    end
  end

  defp leg_fill(state, leg, p, action, reason) do
    model = ContractMonitor.fill_price(p[:price])

    {price, basis} =
      case {p[:bid], p[:ask]} do
        {bid, ask} when is_number(bid) and is_number(ask) and ask > bid ->
          fraction = ContractMonitor.spread_fraction(state, reason)
          {bid, ask} = {Decimal.from_float(bid * 1.0), Decimal.from_float(ask * 1.0)}
          price = bid |> ContractMonitor.touch_price(ask, action, fraction) |> Decimal.round(2)
          mid = bid |> Decimal.add(ask) |> Decimal.div(2)

          {price,
           %{
             "fill_basis" => "quote",
             "fill_bid" => Decimal.to_string(bid),
             "fill_ask" => Decimal.to_string(ask),
             "fill_spread_fraction" => Decimal.to_string(fraction),
             "fill_slippage" => mid |> Decimal.sub(price) |> Decimal.abs() |> Decimal.to_string()
           }}

        _ ->
          {model, %{"fill_basis" => "model_price", "fill_slippage" => "0"}}
      end

    case price do
      nil ->
        :no_price

      %Decimal{} ->
        # A long wing far out of the money can price below a cent; it
        # still fills, at zero, rather than blocking the combo.
        price = Decimal.max(price, 0)

        %{
          leg: leg,
          action: action,
          price: price,
          basis:
            Map.merge(basis, %{
              "leg_index" => leg.leg_index,
              "strike" => Decimal.to_string(leg.strike),
              "right" => leg.right,
              "side" => leg.side
            }),
          commission:
            ContractMonitor.estimate_commission(
              %{multiplier: state.multiplier, quantity: state.quantity * leg.ratio},
              price,
              action
            )
        }
    end
  end

  defp net_of(fills), do: Combo.net_price(Enum.map(fills, & &1.leg), Enum.map(fills, & &1.price))

  defp record_entry(state, snapshot, fills) do
    net = net_of(fills)

    with true <- Decimal.gt?(net, 0) || {:error, :no_credit},
         {:ok, risk} <- Combo.risk_at_entry(state.legs, net, state.multiplier, state.quantity) do
      write_entry(state, snapshot, fills, net, risk)
    else
      {:error, reason} ->
        Logger.warning(
          "ComboMonitor: #{state.symbol} #{state.structure} entry skipped (#{reason}), net #{Decimal.to_string(net)}"
        )

        state
    end
  end

  defp write_entry(state, snapshot, fills, net, risk) do
    context = ContractMonitor.market_context()
    now = DateTime.utc_now()
    {stop, target, risk_context} = ContractMonitor.risk_levels(state, net, snapshot)
    {run, state} = ensure_open_run(state)
    snap = ContractMonitor.stamp(ContractMonitor.jsonify_snapshot(snapshot), context)

    leg_fills =
      Enum.map(fills, fn f ->
        %{
          action: f.action,
          quantity: state.quantity * f.leg.ratio,
          fill_price: f.price,
          filled_at: now,
          commission: f.commission,
          leg_index: f.leg.leg_index,
          pricing_snapshot: Map.merge(snap, f.basis)
        }
      end)

    leg_rows =
      Enum.map(fills, fn f ->
        f.leg
        |> Map.take([:leg_index, :expiry, :strike, :right, :side, :ratio])
        |> Map.put(:entry_price, f.price)
      end)

    entry_context =
      %{
        "regime_label" => ContractMonitor.regime_label(),
        "dte_at_entry" => ContractMonitor.days_to_expiry(state.expiry),
        "implied_volatility" => snapshot["run_implied_vol"],
        "risk_basis" => "max_loss",
        "structure" => state.structure
      }
      |> Map.merge(risk_context)

    case Sim.record_combo_entry_fills(run, leg_fills, leg_rows, %{
           entry_at: now,
           entry_price: net,
           stop_loss_price: stop,
           take_profit_price: target,
           risk_at_entry: risk,
           entry_snapshot: snap,
           context: entry_context
         }) do
      {:ok, {_fills, run}} ->
        Logger.info(
          "ComboMonitor: #{state.symbol} #{state.structure} #{state.expiry} entered for a #{Decimal.to_string(net)} credit"
        )

        Sim.maybe_mark_prior_run_as_churn(state.strategy_version.id, run)

        %{
          state
          | position_open?: true,
            entered_at: now,
            unpriced_warned?: false,
            stop_loss_price: stop,
            take_profit_price: target,
            entry_price: net,
            exit_state: %{}
        }

      {:error, reason} ->
        Logger.error("ComboMonitor: #{state.symbol} combo entry failed: #{inspect(reason)}")
        state
    end
  end

  defp record_exit(state, snapshot, fills, reason) do
    context = ContractMonitor.market_context()
    now = DateTime.utc_now()
    run = Sim.get_sim_run!(state.sim_run_id)
    net = net_of(fills)
    entry_net = run.entry_price || Decimal.new(0)

    realized =
      entry_net
      |> Decimal.sub(net)
      |> Decimal.mult(state.multiplier)
      |> Decimal.mult(state.quantity)

    exit_commission =
      fills |> Enum.map(& &1.commission) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    realized_net =
      case Sim.total_run_commission(run) do
        nil -> nil
        entry_commission -> Decimal.sub(realized, Decimal.add(entry_commission, exit_commission))
      end

    snap = ContractMonitor.stamp(ContractMonitor.jsonify_snapshot(snapshot), context)

    leg_fills =
      Enum.map(fills, fn f ->
        %{
          action: f.action,
          quantity: state.quantity * f.leg.ratio,
          fill_price: f.price,
          filled_at: now,
          commission: f.commission,
          leg_index: f.leg.leg_index,
          pricing_snapshot: Map.merge(snap, f.basis)
        }
      end)

    case Sim.record_combo_exit_fills(
           run,
           leg_fills,
           Map.new(fills, &{&1.leg.leg_index, &1.price}),
           %{
             exit_at: now,
             exit_price: net,
             exit_reason: reason,
             realized_pnl: realized,
             realized_pnl_net: realized_net,
             exit_snapshot: snap
           }
         ) do
      {:ok, _} ->
        Logger.info(
          "ComboMonitor: #{state.symbol} #{state.structure} #{state.expiry} exited at #{Decimal.to_string(net)} (#{reason})"
        )

        %{
          state
          | position_open?: false,
            entered_at: nil,
            last_exit_at: now,
            entry_true_since: nil,
            unpriced_warned?: false,
            stop_loss_price: nil,
            take_profit_price: nil,
            entry_price: nil,
            exit_state: %{}
        }

      {:error, error} ->
        Logger.error("ComboMonitor: #{state.symbol} combo exit failed: #{inspect(error)}")
        state
    end
  end

  # A monitor that went flat and re-enters needs a fresh run, as in
  # ContractMonitor.ensure_open_run/1.
  defp ensure_open_run(state) do
    run = Sim.get_sim_run!(state.sim_run_id)

    if run.status == "closed" do
      {:ok, new_run} =
        Sim.open_sim_run(state.strategy_version, %{
          symbol: state.symbol,
          expiry: state.expiry,
          strike: state.strike,
          right: state.right,
          multiplier: state.multiplier,
          direction: state.direction,
          structure: state.structure
        })

      {new_run, %{state | sim_run_id: new_run.id}}
    else
      {run, state}
    end
  end

  defp skip_unpriced(%{unpriced_warned?: true} = state, _reason), do: state

  defp skip_unpriced(state, reason) do
    Logger.warning(
      "ComboMonitor: #{state.symbol} #{state.structure} #{reason} skipped -- a leg has no price yet; retrying on the next tick"
    )

    %{state | unpriced_warned?: true}
  end

  defp decimal(nil), do: nil
  defp decimal(v) when is_float(v), do: Decimal.from_float(v)
  defp decimal(v) when is_integer(v), do: Decimal.new(v)
  defp decimal(%Decimal{} = v), do: v
end
