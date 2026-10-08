# CLAUDEDAILY.md

The daily operating routine for `trading_options_sim`, the options
paper-trading sim. It has two parts, run at different times:

- **Market-open routine.** Check that the app came through the night
  healthy, then fork new discovery strategies from what is working.
- **Market-close routine.** Check that today's positions were flattened,
  every batch and rollup job finished, then post the day's summary.

Modelled on `../trading_system/CLAUDEDAILY.md`, but much smaller: this
app has two cron jobs, no deploy batches, and no shared position cap.

**If asked to "run CLAUDEDAILY.md" without saying which routine, ask.**
The open routine writes (forks, activations). The close routine only
reads, except for one recovery step (C2).

**This file must match the code.** If a function, field or time here
stops matching the app, fix the file in the same PR.

---

## Schedule (all times UTC)

| Time | What runs | Notes |
|---|---|---|
| 07:00 | `QuarantineEligibilityWorker` (Oban cron) | Counts yesterday's quarantine days, auto-promotes discovery → quarantine, auto-retires failing quarantine versions. |
| 13:30 | US options market opens (EDT; 14:30 during EST) | |
| ~19:49 | `EodCloser` flattens open positions | 11 min before each exchange's close. Versions with `overnight_hold: true` are exempt. |
| 20:00 | Market closes (EDT; 21:00 during EST) | |
| 21:00 | `PerformanceSnapshotWorker` (Oban cron) | Writes one `PerformanceSnapshot` per version with closed runs. Cancels itself if a version that traded got no snapshot. |

**After the clocks change (from 2026-11-01)** the market closes at
21:00 UTC, the same minute the snapshot runs. The `EodCloser` flatten
at ~20:49 UTC still finishes first, but there's little margin, so check
C1 closely during EST.

**Oban cron doesn't backfill.** If the node is down at 07:00 or 21:00,
that day's job never runs. Both routines check for this.

**Run the open routine** after 07:00 UTC and ideally before 13:30 UTC,
so new forks are running at the open. **Run the close routine** after
21:00 UTC, once the snapshot job has had its chance to run.

---

## Before anything else

1. **Talk to the running node over RPC from a separate throwaway node.**
   Never start a second instance (`mix run`, `iex -S mix`) and never
   `iex --remsh`: ending a remote shell can stop the real node. The node
   is registered as **`trading_option_sim`** (no "s"):

   ```sh
   elixir --name dbg$$@Scotts-Mac-mini.local --cookie $(cat ~/.erlang.cookie) \
     --rpc-eval trading_option_sim@Scotts-Mac-mini.local '<Elixir code>'
   ```

   Start the eval'd code with `Logger.configure(level: :info)` to hide
   the SQL debug logs. For anything longer than one line, write a `.exs`
   file in your scratchpad and run `Code.eval_string(File.read!(path))`.
   `epmd -names` lists the running nodes, and the web UI is on port 4013.

2. **Read-only first.** Everything except the fork step (M6) and the
   snapshot recovery (C2) is a query. Never write live data in a step
   that doesn't say to.

3. **`../trading_core` must be on a clean `main`** before you compile
   or restart anything. It's a path dependency, so uncommitted work there
   ships silently into this app.

4. **Guard `MonitorRegistry` selects with `is_binary($1)`.** The
   registry holds more than one kind of process. An unguarded select
   once crashed 50 live monitors.

---

## Market-open routine

Run M0–M7 in order. **On the first trading day of each week, also run
M5b** (the weekly risk-control review) before forking in M6. Stop and
report if M0 or M1 finds the app unhealthy: forking onto a broken app
only hides the problem.

### M0 — Is the app up?

- `epmd -names` lists `trading_option_sim`, and something is listening
  on port 4013.
- Note the boot time (`:erlang.statistics(:wall_clock)`). A restart
  overnight is normal, but every later step should account for it.

### M1 — Did the monitors come back?

Each active version (`activated_at` set, `deactivated_at` nil, not
deleted) should have one `ContractMonitor` per pool member.

```elixir
import Ecto.Query
alias TradingOptionsSim.{Repo, Sim}
active = Sim.list_active_strategy_versions()
expected = active |> Enum.map(&length(Sim.get_target_pool!(&1.target_pool_id).target_pool_members)) |> Enum.sum()
IO.inspect({length(active), expected, Registry.count(TradingOptionsSim.MonitorRegistry)})
```

- The registry count includes some non-monitor processes, so expect it
  to be close to `expected`, not exactly equal.
- If it's well short, `SimReactivator` may still be working through
  activation; after hours each contract lookup can take ~10 s. Check
  again a few minutes later. If the count isn't rising, look for
  `SimReactivator` / `SimActivator` warnings, especially
  `hub_unavailable` (trading_hub not answering).
- `activated_at` must **not** have moved to the boot time. Since PR
  #108 a restart leaves it alone. If every active version shows the
  boot time again, that fix has regressed. Stop and report.

### M2 — Did the overnight jobs run?

```elixir
Repo.all(from j in Oban.Job, where: j.inserted_at > ago(36, "hour"),
  order_by: j.scheduled_at,
  select: {j.worker, j.state, j.scheduled_at, j.completed_at, j.errors})
```

Expect, all `completed`:
- yesterday's 21:00 `PerformanceSnapshotWorker`
- today's 07:00 `QuarantineEligibilityWorker`

| You see | Meaning | Do |
|---|---|---|
| Snapshot job `cancelled` | A version closed runs in the last 24 h but got no snapshot. Its snapshot window, which starts at `activated_at`, is wrong. | Check `activated_at` on the versions that traded. Report; don't re-run the job, since it would duplicate the snapshots it did write. |
| A job missing entirely | The node was down at its cron time. | Quarantine job: tell the user; running `Sim.run_quarantine_eligibility_check(date)` for the missed date is a write and needs their OK. Snapshot job: see C2. |
| `retryable` / `discarded` | The job raised an error. | Report the `errors` text. |

`Sim.cron_worker_health/0` returns the same picture; it's what the
System Performance page shows.

### M3 — Anything left over from yesterday?

```elixir
today = DateTime.new!(Date.utc_today(), ~T[00:00:00])
Repo.all(from r in TradingOptionsSim.Sim.SimRun,
  join: v in assoc(r, :strategy_version),
  where: r.status == "open" and not is_nil(r.entry_at) and r.entry_at < ^today,
  select: {v.id, v.overnight_hold, r.symbol, r.entry_at})
```

- An open position from a previous day on a version with
  `overnight_hold: false` means `EodCloser` missed it. Report it. One
  known cause: an entry filled on the closing tick (`entry_at` at
  exactly the close, e.g. 20:00:00 UTC), after the ~19:49 flatten pass
  had already run. This was seen on 2026-09-30, on 5 QQQ positions.
- Open runs with **no** `entry_at` are monitors waiting for an entry.
  That's normal and fine.
- Don't call `Sim.exclude_runs/2` (reasons `stale_ibkr_data`,
  `orphaned_position`, `duplicate_entry`) without the user's OK. It
  changes every score.

### M4 — What did the lifecycle job change overnight?

Check for versions with `quarantine_started_at` or `retired_reason`
set in the last 24 h, and list them in the summary.

- **Never promote or downgrade a version by hand.** Only the 07:00
  job's own gates move versions automatically. Anything else is the
  user's call.
- Gate values: discovery → quarantine needs ≥ 20 closed runs (with an
  entry) and realized P&L ≥ 0. Quarantine → retired needs ≥ 20
  quarantine trading days and a loss/win ratio > 2.0.
- **LifecycleReview** runs right after the 07:00 job
  (`TradingOptionsSim.LifecycleReview`). It looks at active discovery
  versions with at least 30 trades over at least 3 sessions and negative
  net P&L, and at failing quarantine versions.
  - If one trend x vol regime cell was profitable (at least 15 trades
    over at least 2 sessions, net > 0), it forks the version with an
    entry gate on that regime (tag `Regime-Gated-Fork`) and retires the
    parent (`retired_reason: "lifecycle_review"`). Otherwise it just
    retires the parent. Retired, not deactivated, since 2026-10-08, so
    losers leave /candidates and the leaderboards; unretire + activate
    reverses it.
  - It never touches live-linked or `test_portfolio` versions, controls,
    `Noise-Baseline` or `od:slope-hold`.
  - Mode is `config :trading_options_sim, :lifecycle_review_mode`.
    `:dry_run` (the default) only logs a line like
    `LifecycleReview (dry_run): N regime forks, M retirements`.
    Report the planned actions; switching to `:apply` is the user's call.
- Live-linked versions are now excluded from automatic retirement
  (2026-10-03). Quarantine failure is judged on NET P&L, and losses with
  zero wins count as failing.

### M5 — Rank the discovery leaderboard

```elixir
Sim.full_universe_version_metrics()
```

This returns one row per discovery/quarantine version, computed fresh
from runs. The fields to rank on:

| Field | Meaning |
|---|---|
| `n` | Closed, non-churn, non-excluded trades. Below 30 the gate `N` fails; treat any ranking on fewer than 30 trades as noise and say so. |
| `lcb95` | Lower 95% bound of expectancy in R. The main ranking key: positive means the edge probably survives the sample size. |
| `scored_expectancy_r`, `final_score` | Mean R per trade, and R per capital-hour (scaled by 10^6). Use them to break ties, not to rank on alone. |
| `cost_margin` | Expectancy minus round-trip commission. Below 0 means the edge doesn't cover costs. |
| `exit_reason_histogram` | Gate `X` fails when forced exits (`eod_flatten`, `expiry`, `stop_loss`, `take_profit`) are 70% or more of real exits: the "edge" may just be the stop or the flatten. Mostly `rule_exit` is healthy and passes. |

The `/candidates` page shows the same rows with the nine gate letters
(N S E D X C R G T). The gates are advisory and never block anything.

Compare each family against its control (the "Control: Always-Long …"
version on the same pool). A strategy that doesn't beat buying the
option and holding it has no edge, however it ranks.

For A/B groups (tags like `TP-SL`, `Micro-Filter-AB`, `Vol-AB`),
compare only runs from the group's start date onward.

### M5b — Weekly risk-control review (first trading day of the week)

Read-only, except for one write: re-tagging. The goal is to keep the
default stop/target honest. A stop or target that never fires does
nothing, and one that fires too often turns a good entry into a loss.

**Current default:** `percent_of_entry`, stop 10% / take-profit 20%
(set 2026-10-02). The earlier 15% / 25% almost never fired on 45-DTE
options held intraday (VWAP Spread Reversion Put: 0 of 43 exits).
When this review recommends a new default, change this line in a PR.

1. **How often each setting fires.** Over the last 5 sessions, group
   closed, entered runs by their version's risk settings (method, SL%,
   TP%, ratchet/trailing, or none). For each group report:
   - trades;
   - share of exits by `stop_loss`, `take_profit`, `rule_exit` and
     `eod_flatten`;
   - net P&L per trade.

   ```elixir
   since = DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)
   Repo.all(from r in SimRun, join: v in assoc(r, :strategy_version),
     where: r.status == "closed" and not is_nil(r.entry_at) and is_nil(r.excluded_reason) and r.exit_at >= ^since,
     group_by: [fragment("?->'risk_controls'", v.params), fragment("?->'exit_strategy'", v.params), r.exit_reason],
     select: {fragment("?->'risk_controls'", v.params), fragment("?->'exit_strategy'", v.params), r.exit_reason,
              count(r.id), sum(r.realized_pnl_net)})
   ```

2. **The A/B groups built to answer this,** each against its parent and
   only from its compare-from date:
   - `Exit-Var`: SL10/TP15, SL8/TP25, Ratchet 15/8 and new exit rules;
   - `RC-Added`: SL10/TP20 vs. the same strategy with none;
   - `Vol-AB`: volatility_multiple vs. fixed percent;
   - `TP-SL improved` vs. `TPSL-none`, where both arms are still active.
3. **Versions still without risk controls.** List active versions whose
   `params` have neither `risk_controls` nor `exit_strategy`, other than
   the always-long controls. Tag any new ones `NO Risk Controls`; that's
   this step's only write. Each gets a risk-controls fork in M6.
4. **Recommend.** Give the best-practice settings the data supports,
   per family if they differ (reversion vs. momentum, puts vs. calls),
   with the evidence (n, fire rates, net per trade). Flag anything
   decided on fewer than ~30 trades per arm as provisional. Changing
   the default is the user's call: propose it, don't apply it.

### M6 — Fork new discovery strategies

**This step writes. Activate each new fork immediately**: this is
paper trading, and the user doesn't need to approve each fork.

**Which to fork:**
- Roughly the top 20% by `lcb95` among rows with `n ≥ 30` and
  `cost_margin > 0`.
- If nothing qualifies, fork fewer or none, and say why. Never fork to
  fill a quota.
- **Per-strategy cap:** at most 10% of a strategy's existing version
  count per day, rounded down, minimum 1. If a candidate is at its cap,
  move to the next one and note it.
- **Don't fork** retired versions, or versions whose edge comes from an
  exit artefact (gate `X` failing).

**How to fork.** In this app a fork is a **new Strategy at version 1**
with the parent recorded. The REST API and RPC call the same `Sim`
functions, so either path gives the same result:

```elixir
parent = Sim.get_strategy_version!(parent_id)
{:ok, s} = Sim.create_strategy(%{name: "<Family>: <idea> [<change>]", notes: notes})
{:ok, v} = Sim.create_strategy_version(s, %{
  version: 1,
  parent_version_id: parent.id,
  generation: (parent.generation || 1) + 1,
  rules: new_rules,
  params: new_params,            # min_hold_seconds, risk_controls, exit_strategy
  option_leg_config: leg_config, # right, expiry_selection, dte_target, strike_selection, strike_offset
  position_sizing: parent.position_sizing,
  direction: parent.direction,
  target_pool_id: parent.target_pool_id
})
{:ok, v} = Sim.set_strategy_version_notes(v, "Fork of #{parent.id} (<parent name>). " <> notes)
for t <- tags, do: Sim.add_tag_to_strategy_version_by_name(v, t)
TradingOptionsSim.SimActivator.activate(v)  # expect {:ok, [pids], []}
```

- **Simpler: `fork_version`** (MCP, scope `mcp:write`) or
  `POST /api/v1/versions/:id/fork` (REST, `strategies:write`), both via
  `TradingOptionsSim.VersionFork.fork/2`. Give it `name` plus `entry_gate`
  (AND-ed onto the source entry; exit untouched) **or** `rules` (full
  replacement), and optional `notes`, `tags` and `activate: true`. It
  copies everything else exactly (params including `risk_controls`,
  leg config, pool, sizing, `overnight_hold`, `trading_hours_policy`),
  sets the lineage, appends "Forked from …" to the notes, validates the
  rules and rejects signal names that aren't a monitor key or a known
  trading_signal signal. Changing params, the hold or the contract still
  needs the script above.
- REST equivalents of the script (Bearer token from `/settings`):
  `POST /api/v1/strategies`, then `POST /api/v1/strategies/:id/versions`
  with the same body, then `POST /api/v1/versions/:id/activate`.
- The MCP `create_strategy_version` tool **drops `params`**, so it can't
  set holds, stops or exits. Don't use it for forks.
- Make the script idempotent: skip a name that already exists. Dry-run
  it first: print what it would create without writing.

**One change per fork.** Change the entry, the exit, the hold, the
stop/target, the contract (DTE, strike offset) or the risk sizing, but
only one of them, so the result says which change mattered.

**Every new strategy and fork has risk controls.** `params` must include
`risk_controls`, plus `exit_strategy` where it suits. Use the current
default from M5b unless testing a different setting. If the parent had
none, the fork still gets them: note it, and don't count it as the
fork's one change. The only exception is always-long controls, which
are baselines.

**Other entry params available** (per version, all optional):
- `entry_delay_minutes`: the app default is 5. Set 0 to trade from the
  open. The operator can also override it on a running strategy (the
  "min delay" box on the version page and the Active Strategies row,
  stored in `StrategyVersion.entry_delay_minutes`). Precedence:
  override, then this param, then the app default
  (`TradingOptionsSim.EntryDelay.effective/1`). A change reaches running
  monitors at once. The app default lives only in config (no runtime
  settings store), so changing it needs a restart.
- `entry_confirm_seconds`: the entry rule must hold this long on every
  tick before entering. Use it for flickery signals.
- `reentry_cooldown_seconds`: no re-entry on a contract for this long
  after an exit. Use it against churn.

**Rule tree basics:**
- A rule is `{"entry": node, "exit": node}`. A leaf is
  `{"signal": key, "op": "gt|gte|lt|lte|eq", "value": n}`. Combine
  leaves with `{"all": [...]}`, `{"any": [...]}` or `{"not": node}`.
- **Built-in keys:**
  - option prices and Greeks: `run_current_price`, `run_underlying_price`, `run_delta`, `run_theta` …
  - underlying movement and VWAP: `run_poly_ret_1m_bps`, `run_poly_ret_5m_bps`, `run_poly_vwap_dev_bps`, `run_poly_rel_volume` …
  - regime: `regime_trend_ordinal`, `regime_vol_ordinal`
- A `trading_signal` definition is referenced as
  `"definition:<uuid>"`. The monitor subscribes to it automatically.
- A missing signal counts as **false** (the rule fails closed), so a
  dead feed stops entries; it doesn't cause them.
- **Never use the transition operators** (`crosses_above`,
  `crosses_below`, `sign_flip`, `changed`). This app never supplies the
  previous value they need, so they never fire.
- The comparison ops are `gt`, `gte`, `lt`, `lte`, `eq` and `ne` (`ne`
  since trading_core v0.4.5; before that it silently never fired).
  `StrategyVersion` validates rules with
  `TradingCore.RuleEngine.validate_rules/2` and rejects unknown ops
  (`neq`, `!=` …), transition ops, leaves without a numeric `value` or a
  `value_signal`, `"any": []` and malformed nodes. Check a rule before
  creating it with `StrategyVersion.rules_errors/1`.
- "Always true" is `run_underlying_price gt 0`. "Hold to the
  end-of-day flatten" is `run_underlying_price lt 0`.

**Signal hygiene:**
- **Never use a `trading_signal` definition classified as noise**:
  SPY/QQQ/VIX derivatives, the SPY/QQQ wavelet derivatives and
  accelerations, raw VIX, SPY IV rank, QQQ volume z, XLE signed volume.
  Prefer the persistent ones: wavelet levels, VWAP deviation, self-z
  scores, NYSE TICK, `run_poly_*`.
- Don't use Kyle's lambda as a filter until trading_core's unit
  rescale lands: most readings currently round to 0.
- Before relying on a definition, read its `notes` (the "CAVEATS FIRST"
  block) and check its persistence:

  ```sql
  -- from signal_value_history, persisted every 1 minute
  -- lag-1 autocorrelation near 0, or ~50% sign flips, means noise at this cadence
  ```

- Don't set thresholds from history that predates a known fix:
  - OFI (all symbols): ignore history before 2026-09-28.
  - RSP–SPY spread: ignore history before 2026-09-24.
- A coin-flip signal is still useful as an A/B **filter on top of** a
  persistent parent: the test is whether it beats taking a random half
  of the parent's trades. Never use one as the sole entry trigger.

**Notes and tags (the only memory between runs):**
- **Notes:** start with "Fork of <uuid> (<name>)." Then give:
  - the hypothesis;
  - the one change made;
  - the expected edge against the ~0.4% round-trip cost;
  - which control it has to beat;
  - any signal caveats.

  Write it so it still makes sense in 90 days.
- **Tags:**
  - always a batch tag, `options-discovery-<YYYY-MM-DD>`;
  - a family tag;
  - an A/B tag when the fork is part of an experiment, plus
    `<tag>-parent` on the parent.
- New experiment groups also go in the user's A/B experiments memory,
  with their compare-from date (normally the next trading day).

### M7 — Morning summary

Report, briefly:
- **App health:**
  - boot time;
  - monitors running vs. expected;
  - whether `activated_at` held.
- **Overnight jobs:** each job's state; the snapshot count and `missed`.
- **Leftovers:** positions EodCloser missed, if any.
- **Lifecycle changes:** promoted / retired overnight.
- **Leaderboard:** the top 5 and bottom 5 by `lcb95` (with `n`), and
  how each compares with its control.
- **Forks created:**
  - name, parent and the one change;
  - candidates skipped because of the per-strategy cap.
- **Weekly risk-control review (M5b, first trading day of the week):**
  - fire rates and net per trade by setting;
  - the A/B results;
  - versions newly tagged `NO Risk Controls`;
  - the recommended defaults.
- **Problems:** anything needing the user's decision.

---

## Market-close routine

Mostly read-only. Run after 21:00 UTC (22:00 during EST).

### C0 — Were today's positions flattened?

```elixir
Repo.all(from r in TradingOptionsSim.Sim.SimRun,
  join: v in assoc(r, :strategy_version),
  where: r.status == "open" and not is_nil(r.entry_at) and v.overnight_hold == false,
  select: {v.id, r.symbol, r.entry_at})
```

- After ~19:49 UTC (EDT) this should be empty.
- Anything left is a position `EodCloser` didn't flatten: report the
  version and symbol.
- Positions on `overnight_hold: true` versions are expected to stay open.

Also check today's exit-reason mix (`eod_flatten`, `rule_exit`,
`stop_loss`, `take_profit` …). A day of almost all `eod_flatten` exits
means the exit rules aren't firing.

### C1 — Did the snapshot job run, and cover everyone?

Find today's 21:00 `PerformanceSnapshotWorker` job in `oban_jobs`.

| State | Do |
|---|---|
| `completed` | Check that today's snapshot count matches the number of snapshot-eligible versions with an entered, closed, non-excluded run. Expect them to be close. |
| `cancelled` | Its `errors` say how many versions were missed. Their `activated_at` is wrong: check whether a restart reset it, and report. Don't re-run the job (it would duplicate the rows it did write). |
| missing | The node was down at 21:00. Go to C2. |

### C2 — Recover a missed snapshot (the only write)

Only if C1 found **no** snapshot job for today, at all, in any state:

```elixir
Oban.insert!(TradingOptionsSim.Sim.Workers.PerformanceSnapshotWorker.new(%{}))
```

Wait for it to complete, then repeat C1.

- Never enqueue a second one on a day that already has one. The table
  is append-only, so it would double the day's rows.
- Tell the user it was run by hand.

### C3 — Is the job queue empty?

```elixir
TradingOptionsSim.Sim.oban_pending_job_count()
```

- Expect 0. Anything `available`, `scheduled`, `retryable` or
  `executing` after the close is stuck work: report the worker and
  errors.
- Also report any job `discarded` or `cancelled` today.

### C4 — Did this morning's forks run?

For each version created in M6:
- its monitors are running;
- it isn't missing contracts (`activate` returned
  `unsubscribed_symbols`);
- its `definition:` signals arrived (the monitor's `last_snapshot` has
  the key);
- whether it entered at all.

A fork that never entered because one of its signals never arrived is a
setup problem, not a result.

### C5 — Close summary

Report:
- **Today's results:** closed trades and realized P&L (gross and net)
  across all versions; the top 5 and bottom 5 versions by today's net
  P&L.
- **Close checks:**
  - positions not flattened (C0);
  - snapshot job state, count and `missed` (C1);
  - whether C2 was needed;
  - pending/failed jobs (C3).
- **This morning's forks:** how each one did (C4).
- **Tomorrow:** anything the open routine should check first.

Two things happen at tomorrow's 07:00 job, not tonight: quarantine day
counts, and promotion/retirement. Don't expect them in tonight's numbers.

---

## Never

- Never place a real order or touch `trading_live`. This app is paper
  only.
- Never promote or downgrade a version by hand (API, MCP or `Sim`).
  Lifecycle changes are the 07:00 job's or the user's.
- Never broadcast on `TradingHub.PubSub` or `TradingSignal.PubSub` from
  this node. Subscribe only.
- Never edit another app's code or data (`trading_signal` notes,
  `trading_hub`, `trading_core`). Draft a prompt for that app's session
  instead.
- Never `exclude_runs`, backfill, or otherwise rewrite run or version
  history without the user's OK.
- Never re-run `PerformanceSnapshotWorker` on a day it already ran.
- Never use a noise-classified signal in a new strategy.
- Never create a strategy version without risk controls (`risk_controls`
  and/or `exit_strategy`), except an always-long control.
- Never `iex --remsh` into the live node, or start a second instance of
  the app.
