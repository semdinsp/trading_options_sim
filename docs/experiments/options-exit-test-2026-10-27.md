# Options exit test (pre-registration)

Experiment tag `Options-Exit-Test-2026-10-27`. Written 2026-10-26, after
the close and before any fork existed. Requested by trading_system after
its own exit test (tag `exit-test-2026-10-02`, read out 2026-10-26). There,
reachable equity targets beat a distant 2% target, by +4 to +7.5 bps per
session, with 95% intervals that included zero, and no arm was profitable
overall.

**Question.** Do reachable option targets, sized from this app's own
premium MFE, beat the parents' distant targets? The parents use TP20 or
TP25, which is hit on 0–7% of exits.

## Parents (controls)

Chosen 2026-10-26 from active versions with ≥ 10 sessions and ≥ 30 closes
since 2026-09-28, ranked by mean net return per trade (premium basis):

| Parent | Version | n | Sessions | Net/trade | Current exit | TP hit |
|---|---|---|---|---|---|---|
| XLE VWAP Trend Call | `01a0f313-92d7` | 44 | 18 | +1.30% | SL15/TP25, rule exit | 7% |
| Donchian Put [Exit: Donchian Flip] | `01a12367-83e0` | 98 | 11 | +0.38% | SL10/TP20, rule exit | 1% |
| Donchian Put [Cooldown 30m] | `01a12367-83a2` | 83 | 11 | +0.28% | SL10/TP20, rule exit | 5% |
| TLT Volume Breakout Call [TP-SL] | `01a0d92d-d6de` | 45 | 20 | +0.22% | SL15/TP25, rule exit | 4% |
| Poly: Volume Breakout Call [OFI-Confirmed] | `01a10de8-cf60` | 37 | 13 | +0.14% | SL10/TP20, rule exit | 0% |
| TLT VWAP Trend Call [Entry: Donchian] | `01a112f1-fa1d` | 48 | 14 | +0.01% | SL10/TP20, rule exit | 6% |

Skipped, and why:
- **Noise-signal entries** (fc6b3f93, de76da4a). These are standing exclusions.
- **Always-long controls.**
- **Near-duplicates:**
  - the XLE [OFI>0] / [Tight-Book] / [BookImb] variants, which have the same trades as XLE VWAP Trend Call;
  - TLT Volume Breakout and VWAP Trend without RC, which duplicate the [TP-SL] and [Donchian] versions above.
- **Both RSP parents** (`7f61`, `f7ef`). Only 4/20 and 9/57 of their recent fills priced against a two-sided quote, and Polygon has 0–4 minute bars for their contracts. A take-profit test on model prices says little.
- **TS: TICK Positive Call [TICK MA5]** (n = 30). Its exit is a vol-sized stop plus a ratchet, so "change only the target" isn't well defined.

`83e0` and `83a2` share the same entry, so their results are correlated.

## Arms

Each parent is forked three ways. Only `params.risk_controls.take_profit_percent`
changes, or `params.exit_strategy` is added. The following are copied unchanged:
- entry rule, exit rule and min hold;
- legs, DTE and strike;
- sizing and pool;
- the stop and cooldown.

Every parent keeps running on the same dates as the control.

Sizing comes from premium MFE on the parents' own closes since 2026-09-28.
MFE was measured from Polygon 1-minute bars of each option contract,
between entry and exit. This app doesn't record MFE (see "Gaps" below).

| Parent | With bars | Winners' MFE p50 | p75 | MFE ≥ current TP | `tp-mfe-p50` | `tp-mfe-p75` | `trail-mfe-p50` |
|---|---|---|---|---|---|---|---|
| `92d7` XLE | 27/44 | 7.3% | 14.3% | 0% (TP25) | SL15/TP7 | SL15/TP14 | SL15/TP25 + trail 7% |
| `83e0` | 66/98 | 5.1% | 8.1% | 3% (TP20) | SL10/TP5 | SL10/TP8 | SL10/TP20 + trail 5% |
| `83a2` | 66/83 | 3.7% | 9.2% | 5% (TP20) | SL10/TP4 | SL10/TP9 | SL10/TP20 + trail 4% |
| `d6de` TLT | 43/45 | 9.8% | 17.4% | 2% (TP25) | SL15/TP10 | SL15/TP17 | SL15/TP25 + trail 10% |
| `cf60` | 32/37 | 5.5% | 11.0% | 0% (TP20) | SL10/TP5.5 | SL10/TP11 | SL10/TP20 + trail 5.5% |
| `fa1d` TLT | 44/48 | 6.2% | 15.2% | 2% (TP20) | SL10/TP6 | SL10/TP15 | SL10/TP20 + trail 6% |

Pooled over all 278 runs with bars: winners' MFE p50 is 5.7% and p75 is 11.9%.

How the trailing stop works (`TradingCore.ExitStrategy` "trailing"):
- The stop starts following once the premium trades above entry, `trail_pct` behind the best premium seen. It only ever tightens.
- Because `trail_pct` is below the parent's stop, the effective stop on a trade that goes green becomes about `trail_pct`.
- This mirrors trading_system's trailing arm (1% stop, 1% trail).
- The parent's TP is kept, so the arm isolates the trail.
- Stops, targets and trails ignore `min_hold_seconds`, as in the parents.

## Tags

- On every fork and parent: `Options-Exit-Test-2026-10-27`, `Experiment-Hold`.
- Parent tag on each fork and on its parent: `exit-parent:<first 13 chars of parent id>`.
- Arm tags: `exit-arm:tp-mfe-p50`, `exit-arm:tp-mfe-p75`, `exit-arm:trail-mfe-p50`, and on parents `exit-arm:control`.
- Also on parents: `Options-Exit-Test-2026-10-27-parent`.
- On forks: batch tag `options-discovery-2026-10-27`.

`Experiment-Hold` exempts a version from LifecycleReview and from
quarantine job 3 (`Sim.experiment_hold_tag/0`). Without it, five of the six
controls (quarantine, past the 15-session floor) could be retired
mid-test. Remove it at readout.

## Costs assumed (per round trip, % of premium)

These were measured from this app's fills since 2026-10-13 with
`TradeCost.summary/1`: spread crossed versus mid, plus commissions.

| Underlying | Spread | Fees | Round trip | $/round trip |
|---|---|---|---|---|
| SPY/QQQ (`83e0`, `83a2`, `cf60`) | 0.26–0.29% | 0.08–0.10% | **~0.37%** | $7.5–9.5 |
| TLT (`d6de`, `fa1d`) | 0.6–0.7% | 1.1–1.2% | **~1.8%** | ~$3.2 |
| XLE (`92d7`) | 1.9% | 0.6% | **~2.5%** | ~$8 (only 15/24 fills quoted) |

A TP5 target clears SPY/QQQ costs about 13×. A TP7 on XLE clears its costs
less than 3×, so that arm is expected to lose most of its gross edge to cost.

## Decision rule (fixed before any results)

**Data.**
- Closed, non-excluded, single-leg runs with `exit_at` on or after 2026-10-27 (America/New_York session date).
- The arm and its control are compared only on the same sessions.
- No reading from a single session.

**Return per trade.**
- Before costs: mid-to-mid premium return, which is the fill return plus `spread_paid / capital`.
- After costs: `realized_pnl_net / capital`, which includes spread and commissions as filled.
- Both are reported.

**Primary statistic: the paired per-session gap, after costs.**
1. For each (parent, session) where both the arm and its control closed ≥ 1 trade, compute d = arm session mean − control session mean.
2. Average d across parents, equally weighted, for each session. This gives one value per session per arm.
3. Report the mean, a t-based 95% CI over sessions, and sessions won (d > 0).
4. Per-parent pairs are reported as a secondary breakdown.

**Readout.**
- At the first close where every arm has ≥ 10 paired sessions and ≥ 100 closes, pooled over its parents.
- Expected around 2026-11-09: about 25 closes per arm per session.
- If an arm hasn't reached 100 closes after 20 sessions, it is reported as underpowered, with whatever n it has.

**Verdicts per arm.**
- **Better exit:** the 95% CI of the paired Δ after costs lies entirely above 0. This alone doesn't make it profitable. That needs the per-trade net lcb95 > 0, reported separately.
- **Inconclusive:** mean Δ > 0 but the CI includes 0. One extension of 10 sessions is allowed, then a final verdict.
- **Worse or no better:** mean Δ ≤ 0.

**Readout table, per arm:**
- closes, sessions;
- mean per-trade return before and after costs, with lcb95;
- paired Δ versus control (mean, 95% CI, sessions won);
- exit mix (target / stop / trail / rule / EOD / expiry, %);
- median hold.

Trail versus stop: both are recorded as `exit_reason "stop_loss"`. A
`stop_loss` exit whose run's final `stop_loss_price` is above the initial
level (entry × (1 − SL%) for a long) counts as a trail exit.

## Gaps found in this app

1. **No MFE or MAE capture.**
   - `SimRun` stores no excursion, and the trailing high-water mark lives only in `ContractMonitor` state.
   - The sizing above used Polygon option minute bars, which are trade prints, not the mid this sim marks to. That likely overstates MFE a little.
   - Polygon also refused bars for the current session (plan tier) and had none for 4 contracts.
2. **Trailing exits aren't labeled.** They are recorded as `stop_loss`, so the exit mix has to infer them as described above.
3. **No way to keep a control running past the lifecycle jobs.** Added `Experiment-Hold` (this branch) for that.
4. **`VersionFork` can't override `params`.** The forks were made by calling `Sim.fork_strategy_version/2` with a copy of the parent whose `params` had changed: same transaction, same changeset validation.
