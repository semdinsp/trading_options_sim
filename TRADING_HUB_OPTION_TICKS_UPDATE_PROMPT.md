# Handoff prompt: option ticks/greeks broadcast support in `trading_hub`

Status: not yet sent. Paste the section below into a Claude Code session
running **inside `trading_hub`'s own directory** (`../trading_hub` from
here) — per this workspace's cross-app boundary rule, that work must
happen in that app's own session, not edited from `trading_options_sim`
or any other sibling app's session.

## Why this exists

`trading_options_sim` (see this directory's `OPTIONS_SIM_ARCHITECTURE_PLAN.md`
§5a) prices options synthetically in v1 (Black-Scholes) precisely
*because* no real IBKR option quote feed exists yet to consume. v2 of
that same section — swapping in real quotes/greeks — depends entirely
on the gap this prompt describes. Verified directly against
`trading_hub`'s current code on 2026-09-13 (not from a secondhand
report): two of the three pieces needed for this are **already done**;
this prompt is only about the piece that isn't.

## What's already done — do not redo this

- `TradingHub.IBKR.ContractResolver.resolve/4` resolves
  `(symbol, expiry, strike, right)` to a cached `con_id` via
  `reqContractDetails`. Unchanged, working, PR #101.
- `TradingHub.IBKR.Subscriptions.send_req_mkt_data/3` already reads
  `:expiry`/`:strike`/`:right`/`:multiplier` off a subscription's
  contract map and places them correctly in the `reqMktData` wire frame
  — confirmed end-to-end from `TradingHub.MarketData.Manager.subscribe_symbol/3`
  down to the socket write. The caller must pass the option's OCC-style
  `local_symbol` as `symbol` (not the bare ticker), per that module's
  own doc comment, to avoid colliding with the underlying stock's own
  subscription key.

## What's missing — confirmed by direct grep, zero hits

```
grep -rn "TickOptionComputation" trading_hub/lib trading_hub/test
# (no results)
```

`tws_api` already decodes `TickOptionComputation` (msg id 21 — implied
vol, delta, gamma, vega, theta, and the option's/underlying's price;
see `tws_api/lib/tws_api/messages.ex` and `message_parser.ex`, PR #25).
Nothing in `trading_hub` ever reads that struct. Concretely:

1. `TradingHub.IBKR.MessageHandler.handle/1` has no clause for
   `%Messages.TickOptionComputation{}` — it never becomes a broadcast at
   all. Add one, mirroring how the existing `TickPrice`/`TickSize`
   clauses build a `TradingHub.Message` from `symbol_for(req_id)` plus
   the tick payload.
2. `TradingHub.Message` has no option-aware identity or message type.
   Its only `:price` clause (`to_topic/1`, e.g.
   `to_topic(%__MODULE__{type: :price, symbol: symbol}) when
   is_binary(symbol)`) derives the topic purely from a bare `symbol`
   string, with no `con_id`/expiry/strike/right fields on the struct at
   all. Even a plain option price tick via the already-working
   `TickPrice`/`TickSize` subscription path carries identity only by
   convention (whatever OCC-style string a caller subscribed with) —
   there's no structural way for a consumer to know it's looking at an
   option contract, let alone which one. This needs either:
   - new struct fields (`con_id`, and/or `expiry`/`strike`/`right`) on
     `TradingHub.Message` plus a `to_topic/1` clause that produces an
     unambiguous per-contract topic, or
   - a distinct `:greeks`/`:option_price` message type carrying that
     identity explicitly, separate from the existing stock-shaped
     `:price` type.
   Pick whichever fits this app's existing `TradingHub.Message` design
   better — this prompt doesn't mandate which, only that *some*
   structural (not convention-only) identity must exist before a
   consumer app can reliably tell contracts apart.
3. `ContractResolver.resolve/4` is not wired to the subscription path
   anywhere — nothing currently calls it and then turns the resulting
   `con_id` into a `Subscriptions.subscribe/2` call. Decide whether that
   glue belongs in this same piece of work or is a separate follow-up;
   at minimum, note the gap in whatever you ship.

## Frame verification

Same discipline this codebase has already had to apply twice this
week (`OpenOrder`, `ExecDetails` — both had real field-shift bugs that
only a live captured frame caught, after being shipped from
source-reading alone). `tws_api`'s own `TickOptionComputation` decode is
**not yet verified against a real captured frame either** — treat this
whole path as provisional until someone actually exercises it against
live TWS data, not just merged code.

## When done

- Run `mix compile --warnings-as-errors` and `mix test`.
- Report back what shipped, under what message/topic shape, and whether
  it's frame-verified yet — whoever picks up `trading_options_sim`'s v2
  pricing swap-in (§5a of that app's own `OPTIONS_SIM_ARCHITECTURE_PLAN.md`)
  needs that to know what it's consuming.
- Do NOT implement `trading_options_sim`'s own consuming side
  (`TradingOptionsSim.Pricing.IBKRLive`) from this session — that's a
  separate handoff, per this workspace's cross-app boundary rule.

## After this lands

`trading_options_sim`'s own session swaps `ContractMonitor`'s pricing
backend from `TradingOptionsSim.Pricing.BlackScholes` to a real-quote
backend per `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §5a's v2 — the
rule-evaluation snapshot interface is designed not to change shape when
this happens, only what feeds it.
