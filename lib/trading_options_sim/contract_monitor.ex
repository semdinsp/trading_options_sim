defmodule TradingOptionsSim.ContractMonitor do
  @moduledoc """
  One GenServer per `{strategy_version_id, contract_key}` — evaluates a
  strategy version's entry/exit rules against a synthetically-priced
  option contract for exactly one underlying, and records simulated
  fills on a rule transition. See `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §5.

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

  ## Fill pricing

  A fill takes the near touch of the contract's own two-sided quote
  (sell the bid, buy the ask) whenever `IBKRLive` has one, rather than
  the untradeable model mid. A forced close (`"expiry"`, `"eod_flatten"`
  -- see `@forced_exit_reasons`) crosses the full spread, since a
  deadline flatten can't be worked; a rule-triggered fill crosses only
  `:worked_spread_fraction` of it. With no usable quote (the
  Black-Scholes backend, or an IBKR contract whose quote ticks haven't
  arrived) it falls back to the model price. `fill_price_for/4` records
  which basis was used, and the slippage given up, into the persisted
  fill snapshot.

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
  alias TradingOptionsSim.Pricing.PolygonFeatures
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

  # Reasons this app can never work a limit order for: a deadline close
  # goes through at whatever the book shows. These fill at the full
  # touch (sell the bid, buy the ask). Every other fill is a
  # rule-triggered transition a real desk would work, so it crosses only
  # @worked_spread_fraction of the spread.
  @forced_exit_reasons ~w(expiry eod_flatten)

  # Fraction of the bid/ask spread a *worked* (rule-triggered) fill gives
  # up, measured from the mid. 0.5 would be the full touch; the default
  # models getting partially filled inside the spread. Overridable
  # per-monitor via :worked_spread_fraction in start_link/1's opts, same
  # as :implied_volatility.
  @default_worked_spread_fraction 0.25

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
    :worked_spread_fraction,
    :entry_rule,
    :exit_rule,
    :occ_symbol,
    :exchange,
    pricing_backend: :black_scholes,
    ibkr_live_subscribed?: true,
    position_open?: false,
    # Timestamp of the entry FILL (SimFill.filled_at), not of run open
    # or of when the entry rule fired -- see min_hold_elapsed?/1.
    entered_at: nil,
    # Opt-in minimum hold in seconds. nil/absent/0 all mean NO GATE;
    # never defaulted to 0-as-configured, so every already-activated
    # version keeps today's behaviour byte-for-byte. Shared config key
    # with trading_system and trading_live: params["min_hold_seconds"].
    min_hold_seconds: nil,
    last_snapshot: %{},
    signal_names: [],
    canonical_names: %{},
    last_signal_values: %{}
  ]

  @type t :: %__MODULE__{}

  @type contract_key :: {String.t(), String.t(), Decimal.t(), String.t()}

  @doc """
  Builds the `{strategy_version_id, contract_key_string}` Registry key —
  `contract_key` is serialized as a stable string per plan §1
  (`"AAPL:20270115:150.00:C"`).

  Keyed by `strategy_version_id`, not `sim_run_id` — this monitor's
  identity is the (version, contract) pair it's watching, which stays
  stable across an entry/exit cycle even though the `SimRun` underneath
  it closes and (on the next activation) a new one opens. Re-keyed
  2026-09-15 from the original `{sim_run_id, contract_key}` scheme:
  once a run closed, its monitor — genuinely still alive, still
  watching for the next entry signal — became permanently
  undiscoverable by `whereis/2`, since the closed run's own id was the
  only key anything had left to look it up by. Confirmed live: this
  made `StrategyVersionDetailLive` (and `SimActivator.deactivate/1`)
  unable to tell "monitor alive but flat" apart from "never activated"
  the instant a rule-triggered exit fired — both showed as "Not
  running" even though the process was running and correctly evaluating
  ticks. `strategy_version_id` never changes for the life of a running
  monitor, so this gap can't recur.
  """
  @spec registry_key(String.t(), contract_key()) :: {String.t(), String.t()}
  def registry_key(strategy_version_id, {symbol, expiry, strike, right}) do
    {strategy_version_id, "#{symbol}:#{expiry}:#{Decimal.to_string(strike)}:#{right}"}
  end

  def start_link(opts) do
    strategy_version = Keyword.fetch!(opts, :strategy_version)
    contract_key = Keyword.fetch!(opts, :contract_key)

    GenServer.start_link(__MODULE__, opts,
      name:
        {:via, Registry,
         {TradingOptionsSim.MonitorRegistry, registry_key(strategy_version.id, contract_key)}}
    )
  end

  @doc "Looks up the running monitor for `{strategy_version_id, contract_key}`, if any."
  @spec whereis(String.t(), contract_key()) :: pid() | nil
  def whereis(strategy_version_id, contract_key) do
    case Registry.lookup(
           TradingOptionsSim.MonitorRegistry,
           registry_key(strategy_version_id, contract_key)
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

  @doc """
  Points this monitor at a different `SimRun` — call this when reusing
  an already-running (flat) monitor for a fresh activation, before it
  can possibly submit another entry.

  Necessary because this monitor is now long-lived across activate/
  deactivate and entry/exit cycles (`whereis/2` keyed by
  `{strategy_version_id, contract_key}`, not by any one `SimRun` — see
  `registry_key/2`'s own doc), but `state.sim_run_id` was otherwise
  only ever set once, at `init/1`. Confirmed live 2026-09-15 as a real,
  serious bug: `SimActivator.start_or_find_monitor/4` reusing an
  existing monitor for a new run never told it about that new run's
  id, so every subsequent entry/exit after the monitor's very first
  cycle silently overwrote the *original* run's row with fresh
  entry/exit data — one corrupted run was found with `exit_at` earlier
  than its own `entry_at`, from two different real trade cycles
  smashed into one row. A no-op if this monitor is currently mid-
  position (`position_open?: true`) — switching run identity out from
  under an open position would orphan whatever gets submitted next;
  the caller (`SimActivator`) only ever calls this for a monitor it
  already confirmed is flat.
  """
  @spec update_sim_run_id(pid(), String.t()) :: :ok
  def update_sim_run_id(pid, sim_run_id) do
    GenServer.call(pid, {:update_sim_run_id, sim_run_id})
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
      worked_spread_fraction:
        opts
        |> Keyword.get(:worked_spread_fraction, @default_worked_spread_fraction)
        |> to_string()
        |> Decimal.new(),
      entry_rule: entry_rule,
      exit_rule: exit_rule,
      occ_symbol: occ_symbol,
      exchange: Keyword.get(opts, :exchange),
      pricing_backend: pricing_backend,
      ibkr_live_subscribed?: pricing_backend != :ibkr_live,
      position_open?: Keyword.get(opts, :position_open?, false),
      min_hold_seconds: min_hold_seconds(strategy_version),
      signal_names: signal_names,
      canonical_names: canonical_names
    }

    {:ok, state, {:continue, :start_ibkr_live}}
  end

  # Starting the shared IBKRLive listener is deliberately NOT done in
  # init/1. ContractMonitor and IBKRLive are both children of the same
  # DynamicSupervisor (TradingOptionsSim.MonitorSupervisor), and a
  # DynamicSupervisor serves one start_child/2 at a time -- so calling
  # start_child from inside ContractMonitor.init/1 deadlocks: the
  # supervisor is blocked waiting for this init to return, and this init
  # is blocked waiting for the supervisor to start IBKRLive.
  #
  # Observed live 2026-09-17 on the first restart after :ibkr_live was
  # wired up: one monitor sat in `status: :waiting` with a 56-message
  # queue, `Process.alive?` true (so supervision saw a healthy child and
  # nothing ever retried), and monitors 2..10 never started because they
  # were queued behind it on the same supervisor. The stack was exactly
  # gen.do_call -> maybe_start_ibkr_live -> init/1.
  #
  # handle_continue/2 runs immediately after init/1 returns, before any
  # other message is processed, so the listener is still attached before
  # the first tick can arrive -- but the supervisor is free by then.
  @impl true
  def handle_continue(:start_ibkr_live, %{pricing_backend: :ibkr_live} = state) do
    subscribed? =
      start_ibkr_live(
        state.occ_symbol,
        state.symbol,
        state.expiry,
        state.strike,
        state.right
      )

    {:noreply, %{state | ibkr_live_subscribed?: subscribed?}}
  end

  def handle_continue(:start_ibkr_live, state), do: {:noreply, state}

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
  # {strategy_version_id, contract_key}) — each one attach/1es on its own init/1
  # and detach/1es on its own terminate/2, so the listener's real
  # trading_hub subscription only ever drops once every monitor sharing
  # it has gone.
  #
  # Never fatal — a failed real subscribe RPC (see IBKRLive's own
  # moduledoc for why: matches trading_live's StrategyStockMonitor
  # precedent) means this returns false rather than crashing the
  # monitor; the caller (this module's own :snapshot handler, ultimately
  # SimActivator.activate/1 and the UI) is responsible for surfacing
  # that to an operator rather than leaving it a silent log line.
  #
  # Only ever called from handle_continue/2's :ibkr_live clause, never
  # from init/1 — see that callback for the DynamicSupervisor deadlock
  # this ordering avoids.
  defp start_ibkr_live(occ_symbol, symbol, expiry, strike, right) do
    # underlying_symbol is required alongside sec_type/expiry/strike/right
    # — this is what trading_hub actually sends as the wire Contract.symbol
    # field; occ_symbol is purely trading_hub's own tracking key/PubSub
    # topic, not something TWS can resolve an OPT contract from. Confirmed
    # via trading_hub's own PR #105 (subscribe_symbol/3 now returns
    # {:error, {:sec_type_mismatch, ...}} if a bare underlying ticker is
    # reused as the tracking symbol for an option while already subscribed
    # as a stock — this field is what avoids relying on that at all).
    contract = %{
      sec_type: "OPT",
      underlying_symbol: symbol,
      expiry: expiry,
      strike: Decimal.to_float(strike),
      right: right
    }

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
      entered_at: state.entered_at,
      min_hold_seconds: state.min_hold_seconds,
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

  # See update_sim_run_id/2's own doc — a no-op while a position is
  # actually open (mid-position is never a valid time to redirect which
  # run this monitor is tracking), so a caller sequencing this before a
  # potential entry doesn't need its own extra flat-check first.
  def handle_call({:update_sim_run_id, _sim_run_id}, _from, %{position_open?: true} = state) do
    Logger.warning(
      "ContractMonitor: #{state.symbol} ignored update_sim_run_id/2 while a position is open"
    )

    {:reply, :ok, state}
  end

  def handle_call({:update_sim_run_id, sim_run_id}, _from, state) do
    {:reply, :ok, %{state | sim_run_id: sim_run_id}}
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
        snapshot = build_snapshot(priced, spot, signal_values(state))

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
            snapshot = build_ibkr_live_snapshot(tick, spot, signal_values(state))

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

  # Caller-supplied values that sit underneath the pricing keys: the
  # latest trading_signal values plus the underlying's Polygon features
  # (run_poly_*, see PolygonFeatures). Polygon keys are absent, not
  # zero, when stale or unknown, so a rule on them fails closed.
  defp signal_values(state) do
    Map.merge(state.last_signal_values, PolygonFeatures.snapshot(state.symbol))
  end

  # tick.underlying_price (from IBKR's own und_price field, when
  # present) is deliberately preferred over the separately-tracked spot
  # from the underlying's own stock tick when both are available — it's
  # the value IBKR itself used to compute this exact tick's greeks, so
  # it's the more internally-consistent number for run_underlying_price.
  # Falls back to the stock tick's spot only if IBKR didn't send
  # und_price on this particular computation.
  defp build_ibkr_live_snapshot(tick, spot, signal_values) do
    quote_values =
      case Map.get(tick, :quote) do
        nil -> %{}
        q -> %{"run_bid" => q[:bid], "run_ask" => q[:ask], "run_quote_delayed" => q[:delayed]}
      end

    signal_values
    |> Map.merge(%{
      "run_current_price" => tick.price,
      "run_underlying_price" => tick.underlying_price || spot,
      "run_delta" => tick.delta,
      "run_gamma" => tick.gamma,
      "run_theta" => tick.theta,
      "run_vega" => tick.vega,
      "run_implied_vol" => tick.implied_vol
    })
    |> Map.merge(quote_values)
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
    if min_hold_elapsed?(state) and RuleEngine.evaluate(state.exit_rule, snapshot) and
         session_open?(state) do
      submit_exit(state, snapshot, "rule_exit")
    else
      state
    end
  end

  @doc """
  `true` when the rule-based exit is allowed to fire.

  Suppresses ONLY the `rules["exit"]` path for `min_hold_seconds` after
  the entry FILL. Every forced close continues to fire during the
  window: `force_close_expiry/3` (DTE-based) and `do_force_close/2`
  (`EodCloser`, and the operator's `force_close/2`) call `submit_exit/3`
  directly and never reach `maybe_transition/2`, which is the only
  place this gate is consulted.

  That separation is STRUCTURAL, not an exemption list. A list of
  "unless expiry, unless EOD, unless ..." rots the first time someone
  adds a new close path; ordering does not. The forced closes already
  bypass `session_open?/1` for the same reason, so this gate inherits a
  separation the module had already established rather than inventing
  one. Ported from `TradingLive.StrategyStockMonitor.min_hold_elapsed?/1`
  (branch `claude/min-hold-seconds-exit-guard`) -- same config key,
  same `nil`/`0` semantics, same fail-open rule -- so a version
  promoted between the apps behaves identically.

  ## Expiry is the close this must never delay

  In the equities apps the worst case for a wrongly-suppressed exit is
  one delayed exit against a stop that still fires. Here there is no
  stop: `stop_loss`/`take_profit` do not exist in this module, and
  `SimRun.stop_loss_price` has no writer anywhere in this codebase
  (see `Sim.compute_risk_at_entry/3`'s own TODO, which is also why R is
  premium-at-risk rather than stop-distance). The backstop that makes
  the equities argument safe is absent, so the cost of a wrongly
  suppressed exit is bounded only by the premium.

  Worse, `force_close_expiry/3` exists specifically to flatten before
  assignment mechanics this simulator does not model. A gate in front
  of it could carry a position into expiry -- not a delayed exit, but
  an outcome the sim cannot price at all. Hence the sabotage test in
  `contract_monitor_test.exs`: move this gate above the forced closes
  and that test must go red.

  ## Fail open on every ambiguous branch

  No position, no known entry time, or an unexpected shape all return
  `true` (allow the exit). A gate that cannot prove its precondition
  must not silently suppress an exit for a position it knows nothing
  about. The equities apps justify this by noting the harms are not
  comparable; that argument is weaker here for the reason above, so it
  is re-derived rather than inherited: a wrongly allowed exit costs one
  early exit, while a wrongly suppressed one leaves a decaying position
  with nothing underneath to catch it. Failing open is still correct,
  but because it is the safer default for an unprovable precondition,
  not because a stop will clean up afterwards.

  ## Why the gate exists

  `trading_system` measured 60,057 closed runs held under one minute at
  -$30.10/trade NET, with cost drag only ~10% of the gross loss -- those
  trades lose BEFORE costs, so the signals have no edge at that horizon.
  87% of closes were rule exits firing seconds after entry, because
  entry and exit conditions are near-mirror images and noise
  round-trips the position. Observed independently in this app before
  either figure was shared: `SPY VWAP Reversion Call` (entry z < -1.5,
  exit z > -0.5) round-tripped 5 times in ~2 minutes on cent-level
  moves, with commission exceeding P&L on every close.

  This roster is where the gate binds hardest: 30 of 31 versions here
  have an exit rule, against ~27% in `trading_system`.
  """
  @spec min_hold_elapsed?(t() | map()) :: boolean()
  def min_hold_elapsed?(%{min_hold_seconds: nil}), do: true
  def min_hold_elapsed?(%{min_hold_seconds: 0}), do: true

  # Flat, or open with no recorded entry fill time -- fail OPEN.
  def min_hold_elapsed?(%{position_open?: false}), do: true
  def min_hold_elapsed?(%{entered_at: nil}), do: true

  def min_hold_elapsed?(%{min_hold_seconds: seconds, entered_at: %DateTime{} = entered_at})
      when is_integer(seconds) and seconds > 0 do
    hold_ends_at = DateTime.add(entered_at, seconds, :second)
    DateTime.compare(DateTime.utc_now(), hold_ends_at) != :lt
  end

  def min_hold_elapsed?(_state), do: true

  # params["min_hold_seconds"] on the strategy version. Anything that is
  # not a positive integer -- absent, nil, 0, a string, a float -- means
  # no gate, so a malformed value can never silently suppress an exit.
  defp min_hold_seconds(%{params: params}) when is_map(params) do
    case Map.get(params, "min_hold_seconds") do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _absent_or_invalid -> nil
    end
  end

  defp min_hold_seconds(_version), do: nil

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
  # trading_hours_policy is checked first, same precedence
  # trading_live's own transmission_allowed?/1 uses (confirmed by
  # reading that function directly) — "unrestricted" bypasses exchange-
  # hours checking entirely regardless of :exchange, and "extended_only"
  # fails closed regardless of :exchange, before the nil-exchange
  # fail-open/unresolvable-exchange fail-closed rules below ever apply.
  # "regular_and_extended" falls through to the same check as
  # "regular_hours_only" — see trading_hours_policies/0's own doc for
  # why (no real extended-hours session data exists in this app either,
  # matching trading_live's own honestly-a-no-op state for that value).
  #
  # state.strategy_version is loaded once at init/1 and never refreshed
  # — a policy change made via the UI while this monitor is already
  # running only takes effect on its next reactivation, same documented
  # behavior trading_live's own dropdown has (that app's own comment:
  # takes effect on next reactivation, not live-applied mid-session —
  # unlike overnight_hold, which trading_live DOES apply live via
  # PubSub; this app's own overnight_hold is read fresh per EodCloser
  # tick instead, so it doesn't need that same live-apply mechanism).
  defp session_open?(%{strategy_version: %{trading_hours_policy: "unrestricted"}}), do: true
  defp session_open?(%{strategy_version: %{trading_hours_policy: "extended_only"}}), do: false

  defp session_open?(%{exchange: nil}), do: true

  defp session_open?(%{exchange: exchange}) do
    case TradingOptionsSim.ExchangeSessionCache.fetch(exchange) do
      nil -> false
      session -> TradingCore.MarketHours.open?(session, DateTime.utc_now())
    end
  end

  # Confirmed live 2026-09-15 as a real, serious bug distinct from the
  # earlier sim_run_id-staleness one this same run_id field already has
  # a fix for (see update_sim_run_id/2's own doc): that fix only covers
  # SimActivator's own "reuse an already-running monitor for a NEW
  # activation" path. It does nothing for a monitor that goes flat and
  # re-enters entirely on its own, driven purely by rule oscillation,
  # with no activate/1 call in between — state.sim_run_id was never
  # updated in that path at all, so every entry after the monitor's
  # very first one kept calling record_entry_fill/3 on the SAME
  # already-closed run row. entry_changeset/2 never touches `status`,
  # so this silently "resurrected" the row's entry_at/entry_price on
  # each cycle while its dozens of SimFill rows just kept accumulating
  # underneath it — one version was found with 51 fills (26 entry/25
  # exit) attached to a single SimRun row after ~3 minutes of a fast-
  # oscillating signal, its own total_run_commission summing every one
  # of them ($54.40 for what looked like a single one-contract trade in
  # the UI). Fixed by opening a genuinely new SimRun here whenever the
  # run this monitor was last pointed at is already closed — the
  # correct general fix, since SimActivator's own reactivation is just
  # one specific way a monitor can find itself flat with a stale
  # sim_run_id; a purely-internal flat cycle is another.
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
          direction: state.direction
        })

      {new_run, %{state | sim_run_id: new_run.id}}
    else
      {run, state}
    end
  end

  defp submit_entry(state, snapshot) do
    action = if state.direction == "short", do: "sell", else: "buy"
    {price, fill_basis} = fill_price_for(state, snapshot, action, "entry")
    now = DateTime.utc_now()

    {run, state} = ensure_open_run(state)

    case Sim.record_entry_fill(
           run,
           %{
             action: action,
             quantity: state.quantity,
             fill_price: price,
             filled_at: now,
             commission: estimate_commission(state, price, action),
             pricing_snapshot: jsonify_snapshot(Map.merge(snapshot, fill_basis))
           },
           %{
             entry_at: now,
             entry_price: price,
             risk_at_entry: Sim.compute_risk_at_entry(price, state.multiplier, state.quantity),
             entry_snapshot: jsonify_snapshot(Map.merge(snapshot, fill_basis)),
             context: entry_context(state)
           }
         ) do
      {:ok, {_fill, run}} ->
        Logger.info(
          "ContractMonitor: #{state.symbol} #{state.expiry} #{Decimal.to_string(state.strike)}#{state.right} entered at #{Decimal.to_string(price)}"
        )

        Sim.maybe_mark_prior_run_as_churn(state.strategy_version.id, run)

        %{state | position_open?: true, entered_at: now}

      {:error, reason} ->
        Logger.error("ContractMonitor: #{state.symbol} entry fill failed: #{inspect(reason)}")
        state
    end
  end

  defp submit_exit(state, snapshot, exit_reason) do
    action = if state.direction == "short", do: "buy", else: "sell"
    {price, fill_basis} = fill_price_for(state, snapshot, action, exit_reason)
    now = DateTime.utc_now()

    run = Sim.get_sim_run!(state.sim_run_id)
    realized_pnl = realized_pnl(run, price, state)
    exit_commission = estimate_commission(state, price, action)

    # The entry fill's own commission is already persisted; this exit
    # fill's isn't inserted until record_exit_fill/3 below, so
    # total_run_commission/1's sum here is entry-only until we add
    # exit_commission ourselves — matching trading_system's own
    # close_run/3, which sums both legs only after both orders exist.
    realized_pnl_net =
      case Sim.total_run_commission(run) do
        nil ->
          nil

        entry_commission ->
          Decimal.sub(realized_pnl, Decimal.add(entry_commission, exit_commission))
      end

    case Sim.record_exit_fill(
           run,
           %{
             action: action,
             quantity: state.quantity,
             fill_price: price,
             filled_at: now,
             commission: exit_commission,
             pricing_snapshot: jsonify_snapshot(Map.merge(snapshot, fill_basis))
           },
           %{
             exit_at: now,
             exit_price: price,
             exit_reason: exit_reason,
             realized_pnl: realized_pnl,
             realized_pnl_net: realized_pnl_net,
             exit_snapshot: jsonify_snapshot(Map.merge(snapshot, fill_basis))
           }
         ) do
      {:ok, {_fill, _run}} ->
        Logger.info(
          "ContractMonitor: #{state.symbol} #{state.expiry} #{Decimal.to_string(state.strike)}#{state.right} exited at #{Decimal.to_string(price)} (#{exit_reason})"
        )

        %{state | position_open?: false, entered_at: nil}

      {:error, reason} ->
        Logger.error("ContractMonitor: #{state.symbol} exit fill failed: #{inspect(reason)}")
        state
    end
  end

  # Chooses this fill's price and records how it was arrived at.
  #
  # With a real two-sided quote, fills against the book: the full touch
  # for a forced close (see @forced_exit_reasons), otherwise mid plus
  # @worked_spread_fraction of the spread in the direction that hurts.
  # Without one — the BlackScholes backend, or an IBKR contract whose
  # quote ticks haven't arrived — falls back to the model price, which
  # is the pre-existing behavior for every fill in this app.
  #
  # The returned map is merged into the persisted entry/exit snapshot,
  # so `SimFill.pricing_snapshot`'s documented "slippage applied" is a
  # real recorded number rather than an implicit zero.
  #
  # fill_slippage measures from the QUOTE MID, not the model price. It
  # measured from the model price until 2026-09-21, which silently
  # summed execution cost with pricer error -- and for options, where a
  # flat-IV model routinely disagrees with the book, the error term
  # dominated. The symptom was an inversion no execution assumption can
  # produce: a configured fraction of 0.5 realized 0.374 while 0.25
  # realized 0.392, over 8,239 fills. Keep the two quantities separate.
  defp fill_price_for(state, snapshot, action, reason) do
    model_price = fill_price(snapshot["run_current_price"])

    case quote_from(snapshot) do
      nil ->
        # No quote to cross, so no execution cost and no mid to diverge
        # from. nil rather than "0" for the divergence: absent is not the
        # same as measured-and-zero, and conflating them is how the old
        # fill_slippage hid its own defect.
        {model_price,
         %{
           "fill_basis" => "model_price",
           "fill_slippage" => "0",
           "model_mid_divergence" => nil
         }}

      {bid, ask} ->
        fraction = spread_fraction(state, reason)
        price = touch_price(bid, ask, action, fraction) |> Decimal.round(2)
        mid = bid |> Decimal.add(ask) |> Decimal.div(2)

        {price,
         %{
           "fill_basis" => "quote",
           "fill_bid" => Decimal.to_string(bid),
           "fill_ask" => Decimal.to_string(ask),
           "fill_spread_fraction" => Decimal.to_string(fraction),
           # Execution cost: how far this fill crossed from the QUOTE MID.
           # Divided by (ask - bid) this is the realized spread fraction,
           # directly comparable to the configured one above and to an
           # externally measured effective/quoted spread ratio.
           "fill_slippage" => mid |> Decimal.sub(price) |> Decimal.abs() |> Decimal.to_string(),
           # Pricer error: how far the model price sat from the mid. A
           # separate quantity that used to be folded into fill_slippage
           # (see this function's own doc) and is worth keeping -- it is
           # a direct read on how wrong the flat-IV assumption is against
           # a real book, which nothing else in this app measures.
           "model_mid_divergence" =>
             model_price |> Decimal.sub(mid) |> Decimal.abs() |> Decimal.to_string()
         }}
    end
  end

  defp spread_fraction(state, reason) do
    if reason in @forced_exit_reasons do
      Decimal.new("0.5")
    else
      state.worked_spread_fraction
    end
  end

  # Mid, moved `fraction` of the way across the spread against the
  # trader: a buy pays up toward the ask, a sell gives up toward the
  # bid. At fraction 0.5 this is exactly the touch.
  defp touch_price(bid, ask, action, fraction) do
    mid = bid |> Decimal.add(ask) |> Decimal.div(2)
    concession = ask |> Decimal.sub(bid) |> Decimal.mult(fraction)

    if action == "buy",
      do: Decimal.add(mid, concession),
      else: Decimal.sub(mid, concession)
  end

  # A quote is only usable if both sides are present and actually
  # crossed the right way. A zero/negative bid, or an inverted book
  # (crossed or locked quotes do occur, especially around the open and
  # at expiry), would produce a nonsense fill — fall back to the model
  # price rather than inventing one, matching this module's existing
  # "never fabricate a price" posture.
  defp quote_from(snapshot) do
    with bid when is_number(bid) <- snapshot["run_bid"],
         ask when is_number(ask) <- snapshot["run_ask"],
         true <- bid > 0 and ask > bid do
      {to_decimal(bid), to_decimal(ask)}
    else
      _ -> nil
    end
  end

  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)

  # BlackScholes.compute/1 returns a raw float — round to cent precision
  # rather than storing floating-point noise (e.g. 5.1999999999999998) as
  # a fill price. Decimal.from_float/1 itself is exact (preserves every
  # digit of the float's own decimal representation); the precision loss
  # this guards against is upstream, in the float arithmetic itself.
  defp fill_price(price) when is_float(price) do
    price |> Decimal.from_float() |> Decimal.round(2)
  end

  # "run_current_price" is usually a plain float (BlackScholes.compute/1's
  # own return shape, or IBKRLive's tick.price), but a rule tree can
  # reference a run_-prefixed key that a trading_signal broadcast
  # happens to shadow with its own Decimal value (see build_snapshot/3's
  # own doc on run_-prefix precedence) — confirmed live 2026-09-15: a
  # signal-derived Decimal reaching here crashed this GenServer outright
  # with a FunctionClauseError, since only the is_float/1 clause existed.
  defp fill_price(%Decimal{} = price), do: Decimal.round(price, 2)
  defp fill_price(price) when is_integer(price), do: price |> Decimal.new() |> Decimal.round(2)

  # entry_snapshot/exit_snapshot are DB `:map` columns Ecto persists via
  # Jason — but this same snapshot map is also handed to
  # TradingCore.RuleEngine.evaluate/2 for live rule evaluation, whose own
  # type spec explicitly allows `Decimal.t() | number()` values (that's
  # correct and expected there, not a bug to "fix" upstream). Jason has
  # no built-in Decimal encoder (deriving one is a library-wide decision
  # this app doesn't own), so a Decimal value survives evaluation just
  # fine but crashes Ecto's insert/update with
  # Protocol.UndefinedError — confirmed live 2026-09-15: a
  # trading_signal-sourced Decimal in the snapshot crashed submit_entry/2
  # with exactly this error. Converted to a plain string here, at the
  # point of persistence only — the in-memory snapshot RuleEngine
  # actually evaluates against is never touched.
  defp jsonify_snapshot(snapshot) do
    Map.new(snapshot, fn
      {key, %Decimal{} = value} -> {key, Decimal.to_string(value)}
      {key, value} -> {key, value}
    end)
  end

  defp realized_pnl(run, exit_price, state) do
    entry_price = run.entry_price || Decimal.new(0)

    diff =
      if state.direction == "short",
        do: Decimal.sub(entry_price, exit_price),
        else: Decimal.sub(exit_price, entry_price)

    diff |> Decimal.mult(state.quantity) |> Decimal.mult(state.multiplier)
  end

  # Estimated per-fill commission via TradingCore.Costs.IBKR.option_cost/5
  # (Fixed plan, IBKR's published options schedule — see that module's
  # own moduledoc for its unverified-against-real-fills caveats: no ORF,
  # no :tiered support, no percentage-of-notional cap). `notional` is
  # this fill's actual trade value (fill_price × multiplier × quantity),
  # matching order_cost/4's stock analog (`value = fill_price × shares`)
  # rather than a strike-based notional — the fill price is what this
  # contract actually traded at, so it's the more accurate of
  # option_cost/5's own two documented notional choices.
  defp estimate_commission(state, fill_price, action) do
    side = if action == "sell", do: :sell, else: :buy
    notional = fill_price |> Decimal.mult(state.multiplier) |> Decimal.mult(state.quantity)
    TradingCore.Costs.IBKR.option_cost(Decimal.new(state.quantity), notional, side)
  end

  # Exploratory context captured once, at entry, for later per-regime /
  # per-DTE-bucket performance rollups — see the `add_context_to_sim_runs`
  # migration's own comment for why this is a free-form map rather than
  # dedicated columns. `regime_label` is `nil` whenever
  # SignalConnection.current_regime/0 fails (trading_signal unreachable,
  # not yet connected) — a real, distinct "unknown" state, never guessed
  # at or defaulted to a fake label, same fail-closed posture this
  # module already uses for a missing rule-tree signal.
  defp entry_context(state) do
    %{
      "regime_label" => regime_label(),
      "dte_at_entry" => days_to_expiry(state.expiry),
      "implied_volatility" => state.implied_volatility
    }
  end

  defp regime_label do
    case TradingOptionsSim.SignalConnection.current_regime() do
      {:ok, %{label: label}} -> label
      {:error, _reason} -> nil
    end
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
