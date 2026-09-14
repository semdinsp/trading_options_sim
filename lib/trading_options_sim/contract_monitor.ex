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

  Single-leg long/short only (no multi-leg — plan §7). Pricing defaults
  to synthetic (`TradingOptionsSim.Pricing.BlackScholes`, plan §5a v1) —
  no live options tick feed is assumed. Entry/exit rules are evaluated
  via `TradingCore.RuleEngine.evaluate/2` against a snapshot built from
  the current theoretical price/greeks plus a synthetic
  `run_current_price` key (matching the `run_` naming convention
  `TradingCore.RuleEngine`'s own moduledoc documents for caller-supplied,
  non-catalog values).

  ## v2: real IBKR quotes (opt-in, not the default)

  `:pricing_backend` (`:black_scholes` default, or `:ibkr_live`) selects
  `TradingOptionsSim.Pricing.IBKRLive` instead — see that module's own
  moduledoc for the real, confirmed-unverified risk that live greeks
  streaming may simply never arrive (an upstream `trading_hub` question,
  not a bug in this module). When `:ibkr_live` is selected, `:occ_symbol`
  (the exact string `trading_hub`'s own subscription was made with for
  this contract) is required — this module does not derive it, since
  contract-to-OCC-symbol resolution lives outside this app entirely (see
  plan §5a v2's naming note). If no real tick has arrived yet
  (`IBKRLive.latest/1` returns `{:error, :no_data}`), this monitor simply
  does not evaluate that tick — same fail-closed posture
  `TradingCore.RuleEngine` already uses for a missing signal, not a
  fallback to the synthetic pricer (mixing real and synthetic prices for
  the same contract would be worse than waiting).

  ## Expiry handling (plan §5b)

  Tracks DTE (days to expiry, computed from `expiry`'s wire-format
  `"YYYYMMDD"` string) and force-closes with `exit_reason: "expiry"` at
  a configurable cutoff — a new lifecycle event with no stock
  equivalent, since `StrategyStockMonitor` never has to reason about a
  position's own instrument ceasing to exist.

  ## `trading_signal` integration

  On init, resolves `TradingCore.RuleEngine.signal_names/1` against
  `entry_rule`/`exit_rule` and, for each name, calls
  `TradingOptionsSim.SignalBus.request/1` (erpc's `trading_signal` via
  `SignalConnection`, ported from `StrategyStockMonitor`'s identical
  pattern) to resolve it to a canonical topic and subscribe to
  `TradingSignal.PubSub`. An incoming `{:signal, canonical_name, value}`
  broadcast is translated back to the rule tree's own name and merged
  into `last_signal_values` — carried forward into every subsequent
  price-driven evaluation's snapshot (unlike `StrategyStockMonitor`,
  which mutates one long-lived snapshot map directly, this module
  rebuilds its pricing snapshot fresh on every tick — see
  `build_snapshot/2`/`build_ibkr_live_snapshot/2` — so a received signal
  value is stashed separately and merged in at evaluation time instead).

  This app has no `trading_live`-style regime pseudo-signal concept —
  every name `signal_names/1` returns is requested from `SignalBus`
  as-is, no filtering.

  Also subscribes to this app's own local `"trading_signal:connected"`
  topic and re-subscribes on every broadcast there, same as
  `StrategyStockMonitor` — `SignalConnection` broadcasts this on every
  (re)connect, covering both "monitor started before the connection
  existed" and "connection dropped and came back."

  ## Exchange hours (plan §5c)

  `:exchange` (threaded through from `SimActivator`'s `TargetPoolMember`)
  resolves via `TradingOptionsSim.ExchangeSessionCache` to a
  `TradingCore.MarketHours.Session` at evaluation time (`session_open?/1`).
  `:exchange` is optional and predates this gate, so a `nil` exchange
  fails *open* — hours gating is additive, opt-in behavior for a member
  that specifies a real exchange, never a silent trap for one that
  doesn't. An exchange that IS set but doesn't resolve to any seeded
  session still fails closed — that's a real config mistake, not a
  member opting out. Rule evaluation
  and `last_snapshot` always update regardless of hours (same
  "observation always runs" posture `StrategyStockMonitor`'s
  `transmission_allowed?/1` uses for order transmission); only a
  triggered entry/exit transition is skipped outside session hours —
  mapped onto this app's own real action, a `SimFill`, rather than an
  IBKR order. A skipped transition is simply re-evaluated on the next
  tick, same as any other unmet rule condition — nothing is queued or
  remembered across ticks. `force_close_expiry/3` (DTE-based) and
  `TradingOptionsSim.EodCloser`'s force-close both call `submit_exit/3`
  directly, bypassing this gate — a forced flatten must go through
  regardless of hours, same as `trading_live`'s own EOD closer.
  """

  use GenServer
  require Logger

  alias TradingCore.RuleEngine
  alias TradingOptionsSim.Pricing.BlackScholes
  alias TradingOptionsSim.Pricing.IBKRLive
  alias TradingOptionsSim.Sim
  alias TradingOptionsSim.SignalBus

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
    :occ_symbol,
    :exchange,
    pricing_backend: :black_scholes,
    ibkr_live_subscribed?: true,
    position_open?: false,
    last_snapshot: %{},
    signal_names: [],
    canonical_names: %{},
    last_signal_values: %{}
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

  @doc """
  Synchronously flattens any open position (same fail-safe behavior as
  the async `{:force_close_eod, reason}` message `EodCloser` sends — a
  no-op if flat, or if no snapshot has been priced yet) and only then
  returns. `SimActivator.deactivate/1` calls this before terminating
  the monitor's own supervisor child, so a deliberate deactivation can
  never race "the process gets killed before its exit fill is
  recorded" the way sending `{:force_close_eod, reason}` and
  immediately calling `DynamicSupervisor.terminate_child/2` could.
  `reason` is stored as `SimRun.exit_reason` via `to_string/1` — pass
  an atom (`:manual`, matching `trading_live`'s own established
  operator-triggered-close convention) or a string.
  """
  @spec force_close(pid(), atom() | String.t()) :: :ok
  def force_close(pid, reason) do
    GenServer.call(pid, {:force_close, reason})
  end

  @impl true
  def init(opts) do
    sim_run_id = Keyword.fetch!(opts, :sim_run_id)
    {symbol, expiry, strike, right} = Keyword.fetch!(opts, :contract_key)
    strategy_version = Keyword.fetch!(opts, :strategy_version)
    direction = Keyword.get(opts, :direction, "long")
    quantity = Keyword.get(opts, :quantity, 1)
    multiplier = Keyword.get(opts, :multiplier, 100)
    pricing_backend = Keyword.get(opts, :pricing_backend, :black_scholes)
    occ_symbol = Keyword.get(opts, :occ_symbol)

    if pricing_backend == :ibkr_live and is_nil(occ_symbol) do
      raise ArgumentError, ":occ_symbol is required when :pricing_backend is :ibkr_live"
    end

    Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, "prices:#{symbol}")

    ibkr_live_subscribed? =
      maybe_start_ibkr_live(pricing_backend, occ_symbol, expiry, strike, right)

    rules = strategy_version.rules || %{}
    entry_rule = Map.get(rules, "entry")
    exit_rule = Map.get(rules, "exit")

    signal_names =
      (RuleEngine.signal_names(entry_rule) ++ RuleEngine.signal_names(exit_rule))
      |> Enum.uniq()

    Phoenix.PubSub.subscribe(TradingOptionsSim.PubSub, "trading_signal:connected")
    canonical_names = subscribe_to_signals(signal_names)

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
      entry_rule: entry_rule,
      exit_rule: exit_rule,
      occ_symbol: occ_symbol,
      exchange: Keyword.get(opts, :exchange),
      pricing_backend: pricing_backend,
      ibkr_live_subscribed?: ibkr_live_subscribed?,
      position_open?: Keyword.get(opts, :position_open?, false),
      signal_names: signal_names,
      canonical_names: canonical_names
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, %{pricing_backend: :ibkr_live, occ_symbol: occ_symbol}) do
    case IBKRLive.whereis(occ_symbol) do
      nil -> :ok
      pid -> IBKRLive.detach(pid)
    end
  end

  def terminate(_reason, _state), do: :ok

  # Starts (or finds an already-running) IBKRLive listener for this
  # contract's OCC symbol when :ibkr_live is selected (a no-op in
  # :black_scholes mode, returns true — "subscribed" is meaningless
  # off this backend), and registers this monitor as depending on it
  # via IBKRLive.attach/1 — see that module's own moduledoc for the
  # real-trading_hub-subscription lifecycle this attach/detach pairing
  # drives. Multiple ContractMonitors for the same contract share one
  # listener (Registry-keyed by occ_symbol, not by this monitor's own
  # {sim_run_id, contract_key}) — each one attach/1es on its own init/1
  # and detach/1es on its own terminate/2, so the listener's real
  # trading_hub subscription only ever drops once every monitor sharing
  # it has gone.
  #
  # Never fatal — a failed real subscribe RPC (see IBKRLive's own
  # moduledoc for why: matches trading_live's StrategyStockMonitor
  # precedent) means this returns false rather than stopping
  # ContractMonitor.init/1; the caller (this module's own :snapshot
  # handler, ultimately SimActivator.activate/1 and the UI) is
  # responsible for surfacing that to an operator rather than leaving
  # it a silent log line.
  defp maybe_start_ibkr_live(:black_scholes, _occ_symbol, _expiry, _strike, _right), do: true

  defp maybe_start_ibkr_live(:ibkr_live, occ_symbol, expiry, strike, right) do
    contract = %{sec_type: "OPT", expiry: expiry, strike: Decimal.to_float(strike), right: right}

    pid =
      case IBKRLive.whereis(occ_symbol) do
        nil ->
          case DynamicSupervisor.start_child(
                 TradingOptionsSim.MonitorSupervisor,
                 {IBKRLive, occ_symbol: occ_symbol, contract: contract}
               ) do
            {:ok, pid} -> pid
            {:error, {:already_started, pid}} -> pid
          end

        pid ->
          pid
      end

    {:ok, subscribed?: subscribed?} = IBKRLive.attach(pid)
    subscribed?
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    reply = %{
      symbol: state.symbol,
      expiry: state.expiry,
      strike: state.strike,
      right: state.right,
      direction: state.direction,
      exchange: state.exchange,
      position_open?: state.position_open?,
      ibkr_live_subscribed?: state.ibkr_live_subscribed?,
      last_snapshot: state.last_snapshot
    }

    {:reply, reply, state}
  end

  # Synchronous counterpart of the {:force_close_eod, reason} message
  # `EodCloser` sends, for a caller (`Sim.deactivate_strategy_version/1`)
  # that must know the flatten attempt has actually completed before it
  # goes on to terminate this process's own supervisor child — see
  # `force_close/2`'s own doc for why that ordering matters. Same
  # fail-safe logic (`do_force_close/2`), just awaited via
  # `GenServer.call/2` instead of fired via `send/2`.
  def handle_call({:force_close, reason}, _from, state) do
    {:reply, :ok, do_force_close(state, reason)}
  end

  # A %TradingHub.Message{type: :price} broadcast from PriceRelay — the
  # underlying's own tick, always subscribed (see init/1). In
  # :black_scholes mode this alone drives evaluation, since the pricer
  # computes the option price on-demand from it. In :ibkr_live mode this
  # is only useful for tracking spot in the snapshot; the real trigger is
  # the option contract's OWN quote/greeks tick, handled below — this
  # matches how a real options tick stream works (the underlying and its
  # option quote arrive as genuinely separate broadcasts), rather than
  # pretending an underlying tick alone tells you anything new about the
  # option's own live price.
  #
  # Recognized structurally (see IbPortfolio.Message's own moduledoc for
  # why this app has no compile-time TradingHub dependency).
  @impl true
  def handle_info(%{__struct__: TradingHub.Message, type: :price, data: data}, state) do
    case underlying_price(data) do
      nil ->
        {:noreply, state}

      spot ->
        case state.pricing_backend do
          :black_scholes -> {:noreply, evaluate_black_scholes(state, spot)}
          :ibkr_live -> {:noreply, evaluate_ibkr_live(state, spot)}
        end
    end
  end

  # A resolved trading_signal value — merged into last_signal_values
  # (never evaluated immediately, unlike StrategyStockMonitor: this
  # monitor's own trigger is always the next price tick, matching
  # evaluate_ibkr_live/2's identical "cache and wait for the next price
  # tick" posture for real greeks).
  def handle_info({:signal, canonical_name, value}, state) do
    name = Map.get(state.canonical_names, canonical_name, canonical_name)
    {:noreply, put_in(state.last_signal_values[name], value)}
  end

  def handle_info(:trading_signal_connected, state) do
    canonical_names = subscribe_to_signals(state.signal_names)
    {:noreply, %{state | canonical_names: Map.merge(state.canonical_names, canonical_names)}}
  end

  # Forced end-of-day close — sent by TradingOptionsSim.EodCloser once
  # this contract's exchange is within its own configured window of
  # closing. Skips maybe_transition/2 (and therefore session_open?/1)
  # entirely — a forced close on a deadline, not a rule-triggered one,
  # same posture force_close_expiry/3 already takes for DTE-based
  # closes. Uses the monitor's own last_snapshot (the most recent priced
  # tick) rather than re-pricing — EodCloser has no spot price of its
  # own to hand back. A flat monitor (no open position, or no snapshot
  # priced yet) is a no-op; `reason` is always `:eod_flatten`.
  def handle_info({:force_close_eod, reason}, state) do
    {:noreply, do_force_close(state, reason)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp do_force_close(%{position_open?: false} = state, _reason), do: state

  defp do_force_close(%{last_snapshot: snapshot} = state, _reason)
       when map_size(snapshot) == 0 do
    Logger.warning(
      "ContractMonitor: #{state.symbol} force-close skipped — no priced snapshot yet"
    )

    state
  end

  defp do_force_close(state, reason) do
    submit_exit(state, state.last_snapshot, to_string(reason))
  end

  # See StrategyStockMonitor.subscribe_to_signals/1's identical
  # implementation/comment for why both the SignalBus.request/1 call and
  # the subsequent Phoenix.PubSub.subscribe/2 are required, and why
  # ArgumentError/:exit here are swallowed rather than crashing this
  # monitor's init/1 — TradingSignal.PubSub or SignalConnection not being
  # up yet just means "retry on the next :trading_signal_connected
  # broadcast," not a fatal error for a contract monitor that may have
  # nothing to do with live signals failing.
  defp subscribe_to_signals(signal_names) do
    Map.new(signal_names, fn name -> {name, SignalBus.request(name)} end)
    |> Enum.reduce(%{}, fn
      {name, {:ok, topic}}, acc ->
        Phoenix.PubSub.subscribe(TradingSignal.PubSub, topic)
        canonical_name = String.trim_leading(topic, "signals:")
        Map.put(acc, canonical_name, name)

      {name, {:error, reason}}, acc ->
        Logger.debug(
          "ContractMonitor: could not request signal #{name}: #{inspect(reason)} " <>
            "— will retry on next :trading_signal_connected"
        )

        acc
    end)
  catch
    :error, %ArgumentError{} ->
      Logger.debug(
        "ContractMonitor: TradingSignal.PubSub not reachable yet, will retry on next :trading_signal_connected"
      )

      %{}

    :exit, _reason ->
      Logger.debug(
        "ContractMonitor: TradingOptionsSim.SignalConnection unavailable, will retry on next :trading_signal_connected"
      )

      %{}
  end

  defp underlying_price(%{last: last}) when is_number(last), do: last

  defp underlying_price(%{bid: bid, ask: ask}) when is_number(bid) and is_number(ask),
    do: (bid + ask) / 2

  defp underlying_price(_data), do: nil

  defp evaluate_black_scholes(state, spot) do
    dte = days_to_expiry(state.expiry)

    cond do
      dte <= 0 and state.position_open? ->
        force_close_expiry(state, spot, dte)

      dte <= 0 ->
        state

      true ->
        priced = price_contract_black_scholes(state, spot, dte)
        snapshot = build_snapshot(priced, spot, state.last_signal_values)

        state
        |> Map.put(:last_snapshot, snapshot)
        |> maybe_transition(snapshot)
    end
  end

  # Every underlying tick in :ibkr_live mode reads whatever the option's
  # own listener last cached (IBKRLive.latest/1) — an underlying tick
  # never blocks on the option quote arriving, it just re-checks the most
  # recent one. {:error, :no_data} (no real tick has arrived for this
  # contract yet) means this evaluation is skipped entirely — fail
  # closed, never fall back to the synthetic pricer for a contract this
  # monitor was explicitly told to price with real quotes (see this
  # module's own moduledoc on why mixing the two would be worse).
  defp evaluate_ibkr_live(state, spot) do
    dte = days_to_expiry(state.expiry)

    cond do
      dte <= 0 and state.position_open? ->
        force_close_expiry(state, spot, dte)

      dte <= 0 ->
        state

      true ->
        case IBKRLive.latest(state.occ_symbol) do
          {:error, :no_data} ->
            state

          {:ok, tick} ->
            snapshot = build_ibkr_live_snapshot(tick, spot, state.last_signal_values)

            state
            |> Map.put(:last_snapshot, snapshot)
            |> maybe_transition(snapshot)
        end
    end
  end

  defp price_contract_black_scholes(state, spot, dte) do
    BlackScholes.compute(%{
      spot: spot,
      strike: Decimal.to_float(state.strike),
      time_to_expiry_years: dte / 365.0,
      risk_free_rate: state.risk_free_rate,
      volatility: state.implied_volatility,
      right: state.right
    })
  end

  # tick.underlying_price (from IBKR's own und_price field, when
  # present) is deliberately preferred over the separately-tracked spot
  # from the underlying's own stock tick when both are available — it's
  # the value IBKR itself used to compute this exact tick's greeks, so
  # it's the more internally-consistent number for run_underlying_price.
  # Falls back to the stock tick's spot only if IBKR didn't send
  # und_price on this particular computation.
  defp build_ibkr_live_snapshot(tick, spot, signal_values) do
    Map.merge(signal_values, %{
      "run_current_price" => tick.price,
      "run_underlying_price" => tick.underlying_price || spot,
      "run_delta" => tick.delta,
      "run_gamma" => tick.gamma,
      "run_theta" => tick.theta,
      "run_vega" => tick.vega,
      "run_implied_vol" => tick.implied_vol
    })
  end

  # signal_values (named trading_signal values, keyed by the rule tree's
  # own signal name) are merged in first so a run_-prefixed pricing key
  # of the same name always wins — matches TradingCore.RuleEngine's own
  # documented run_ precedence convention.
  defp build_snapshot(priced, spot, signal_values) do
    Map.merge(signal_values, %{
      "run_current_price" => priced.price,
      "run_underlying_price" => spot,
      "run_delta" => priced.delta,
      "run_gamma" => priced.gamma,
      "run_theta" => priced.theta,
      "run_vega" => priced.vega
    })
  end

  defp maybe_transition(%{position_open?: false} = state, snapshot) do
    if RuleEngine.evaluate(state.entry_rule, snapshot) and session_open?(state) do
      submit_entry(state, snapshot)
    else
      state
    end
  end

  defp maybe_transition(%{position_open?: true} = state, snapshot) do
    if RuleEngine.evaluate(state.exit_rule, snapshot) and session_open?(state) do
      submit_exit(state, snapshot, "rule_exit")
    else
      state
    end
  end

  # "Observation always runs, the resulting action is what's gated" —
  # same split TradingLive.StrategyStockMonitor's transmission_allowed?/1
  # applies to order transmission, mapped onto this app's own real action
  # (a SimFill, not an order). Rule evaluation above and last_snapshot
  # both already ran unconditionally by the time this is checked; a rule
  # match outside session hours is simply not acted on this tick — it's
  # re-evaluated fresh on the next one, same as any other unmet
  # condition. See OPTIONS_SIM_ARCHITECTURE_PLAN.md §5c.
  #
  # `:exchange` is an optional TargetPoolMember field that predates this
  # gate — every member that existed before exchange-hours support (and
  # any created since through the REST/MCP surface, which still doesn't
  # require it) has `exchange: nil`. Treating that as fail-closed would
  # silently stop every such member from ever filling again, with no
  # error and no way to tell "no signal yet" apart from "gate broken."
  # nil therefore fails OPEN — exchange-hours gating is opt-in, additive
  # behavior for a member that specifies a real exchange, never a
  # silent trap for one that doesn't.
  #
  # An exchange that IS set but doesn't resolve to any seeded
  # ExchangeSession (a real config mistake — e.g. a typo'd exchange
  # code, or one this app genuinely doesn't have hours data for yet)
  # still fails closed: unlike the nil case, this is a member that
  # explicitly opted into hours gating, so silently ignoring the
  # mismatch and filling anyway would hide a real configuration bug
  # rather than surface it.
  defp session_open?(%{exchange: nil}), do: true

  defp session_open?(%{exchange: exchange}) do
    case TradingOptionsSim.ExchangeSessionCache.fetch(exchange) do
      nil -> false
      session -> TradingCore.MarketHours.open?(session, DateTime.utc_now())
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
