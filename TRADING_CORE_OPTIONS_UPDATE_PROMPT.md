# Handoff prompt: add options/contract-multiplier support to `trading_core`

Status: not yet sent. Paste the section below into a Claude Code session
running **inside `trading_core`'s own directory** (`../trading_core` from
here) — per this workspace's cross-app boundary rule, that work must
happen in that app's own session, not edited from `trading_options_sim`
or any other sibling app's session.

## Why this exists

`trading_options_sim` (see this directory's `OPTIONS_SIM_ARCHITECTURE_PLAN.md`)
is being built to reuse `trading_core`'s shared, pure logic for rule
evaluation, exit strategy, position sizing, and risk controls — the exact
same reasoning that already makes `trading_system`'s paper simulator and
`trading_live`'s real GenServers behave identically (see each module's own
moduledoc: "one place to fix if a formula ever changes, not two copies
that can silently drift apart"). That guarantee should extend to
`trading_options_sim` too, not fork into a third, options-specific copy.

**The gap, confirmed by reading the current code**: none of
`TradingCore.PositionSizing`, `TradingCore.RiskControls`, or
`TradingCore.ExitStrategy` know anything about a contract multiplier.
Every dollar calculation in all three assumes one unit == one dollar of
underlying price movement (a stock share). An option contract typically
represents 100 shares of the underlying — a $2.00 move in the option's own
premium is a $200 move in real P&L per contract, not $2. Concretely:

- `PositionSizing.calculate_qty/2`'s `"volatility_target"` clause computes
  `target_dollar_volatility / (daily_vol * price)` — if `price` is an
  option's per-share premium and the multiplier isn't factored in
  somewhere, the resulting quantity (in contracts) would be sized as if
  each contract only controlled 1 share of exposure, not 100. That's a
  100x sizing error if a caller passes option premium through unchanged.
- `RiskControls.levels/3`'s stop-loss/take-profit percent-of-entry math
  computes correctly *as a percentage of premium* regardless of
  multiplier (a 20% stop-loss on a $5.00 option is $4.00 either way) —
  but the caller needs the *dollar* risk (for e.g. a max-dollar-risk-per-trade
  gate, or the audit/reporting side), which does require the multiplier.
  Confirm this distinction explicitly rather than assuming — percent-based
  levels may not need any change at all; dollar-conversion call sites are
  the ones that do.
- `ExitStrategy.check/5`'s ratchet/trailing math is also purely
  percent-of-price — same "confirm whether this needs to change or just
  needs a caller-side dollar conversion" question applies.
- `RuleEngine` itself is multiplier-agnostic by design (it only compares
  named signal values against a snapshot, never computes dollars) — almost
  certainly needs no change; confirm this rather than assume it, since a
  rule like `"run_current_price" lte "run_stop_loss_price"` still just
  compares prices either way, multiplier never enters into it.

## Prompt to paste into a `trading_core` session

```
trading_options_sim (a new sibling app, see
/Users/scottsproule/Documents/programming/elixir/dream/ibkrpubsub/trading_options_sim/OPTIONS_SIM_ARCHITECTURE_PLAN.md
for its full design) needs to reuse this library's shared trading logic
for options the same way trading_system/trading_live already share it for
stocks — one set of formulas, not a third options-specific fork. Read
that plan doc's §1 (contract identity) and §2 (StrategyVersion schema,
option_leg_config) for the shape of what a caller will have on hand: an
underlying symbol, strike/expiry/right, and (once resolved) a contract
multiplier (typically 100 for standard US equity options, but not
guaranteed — some non-standard/adjusted contracts differ).

The task: audit TradingCore.PositionSizing, TradingCore.RiskControls,
and TradingCore.ExitStrategy for exactly where a contract multiplier
needs to enter the calculation, and add support for it — WITHOUT
changing behavior for existing stock callers (trading_system,
trading_live), whose multiplier is implicitly 1 and must stay that way
with zero code changes on their end.

Specifically:

1. TradingCore.PositionSizing.calculate_qty/2 — the "volatility_target"
   method's target_dollar_volatility / (daily_vol * price) formula needs
   a multiplier factored in somewhere so the result is sized in CONTRACTS
   correctly, not as if each contract were 1 share of exposure. Design
   question to resolve, not assume: does this take a new optional
   context[:contract_multiplier] key (default 1, so an omitted key is a
   no-op for existing callers), or does it stay as-is and push the
   multiplier adjustment onto the caller (trading_options_sim) instead?
   Read this module's own moduledoc "Fractional shares" section first —
   it's the precedent for how a new options-only concern was previously
   added to this module (context[:fractional_shares_enabled]) without
   touching non-options callers; match that pattern's shape.

2. TradingCore.RiskControls.levels/3 and TradingCore.ExitStrategy.check/5
   — determine whether either function's own math needs a multiplier at
   all (their inputs/outputs are prices and percentages, not dollar P&L,
   so they may not), or whether the multiplier only matters at whatever
   call site converts a price-based stop/take-profit level into a dollar
   risk figure (which may already live outside this library, in each
   consuming app). Do not add an unused parameter defensively — only
   change what the actual math requires. Document the conclusion in
   each module's own moduledoc either way (even "no change needed,
   because X" is worth recording, so a future reader doesn't reopen this
   question from scratch).

3. Confirm TradingCore.RuleEngine needs no change (it compares named
   signal values, never computes a dollar amount) — this is almost
   certainly already true; treat this as a verification step, not a
   build step.

4. Every option_leg_config field trading_options_sim's plan describes
   (right, expiry_selection, strike_selection, target_delta) is specific
   to CHOOSING a contract, not to sizing/risk/exit math once a contract
   is already chosen — this library's job is narrowly the multiplier
   question above, not contract selection logic. Don't build a
   strike/delta selector here; that's trading_options_sim's own
   ContractMonitor (see the plan doc §5).

For each function you touch:
- Preserve the "deliberately pure — no RPC, no I/O" constraint already
  documented on PositionSizing/RiskControls/ExitStrategy.
- All arithmetic stays Decimal, never floats (existing convention in
  every one of these modules).
- Add/update the moduledoc explaining the WHY (mirroring how
  "Fractional shares" explains PositionSizing's existing options-adjacent
  precedent) — future readers in trading_system/trading_live need to
  understand why a new parameter exists even though they'll almost
  certainly never set it to anything but the default.
- Existing trading_system/trading_live tests must continue passing
  unchanged — a multiplier default of 1 (or an equivalent no-op default)
  is the guardrail; run their test suites too if convenient, though a
  passing `mix test` in this repo plus unchanged public function
  signatures (only added optional params) is the real bar.
- Add new tests for the multiplier-aware path using realistic options
  numbers (e.g. a $5.00 premium, 100 multiplier, $500 target dollar
  volatility) so the 100x-sizing-error scenario this prompt describes is
  the thing actually being regression-tested.

Run mix compile --warnings-as-errors and mix test when done. Report back:
which functions changed, what the multiplier default/opt-in mechanism
ended up being, and confirm trading_system/trading_live's own call sites
need zero changes to keep working.
```

## After this lands

`trading_options_sim`'s own `ContractMonitor` (§5 of that app's
architecture plan) is the consumer — once this work ships, that app's
build sequencing step 3 (options pricing) and step 4 (`ContractMonitor`)
should thread the resolved contract's multiplier through to whichever of
`PositionSizing`/`RiskControls`/`ExitStrategy` ends up taking it, per
whatever mechanism this session designs.
