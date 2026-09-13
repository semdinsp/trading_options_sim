# Handoff prompt: add options support to `tws_api`

Status: not yet sent. Paste the section below into a Claude Code session
running **inside `tws_api`'s own directory** (`../tws_api` from here) —
per this workspace's cross-app boundary rule, that work must happen in
that app's own session, not edited from `trading_options_sim` or any
other sibling app's session.

## Why this exists

`trading_options_sim` (see this directory's `OPTIONS_SIM_ARCHITECTURE_PLAN.md`)
is being built as an options paper-trading simulator. Its v1 (§5a of that
plan) deliberately prices options synthetically (Black-Scholes) precisely
*because* `tws_api` has no options wire support yet — so `trading_options_sim`
is not blocked waiting for this work. But v2 of that same section — swapping
in real IBKR option quotes/greeks — depends entirely on the work below, and
nothing currently drives it forward. This prompt is what starts that clock.

`trading_options_sim` doesn't touch `tws_api` at all, even indirectly — it
would consume this eventually through `trading_hub`/`ib_portfolio`'s market
data relay, the same path `trading_live` already uses for equities.

---

## Prompt to paste into a `tws_api` session

```
Read /Users/scottsproule/Documents/programming/elixir/dream/ibkrpubsub/OPTIONS_LEAPS_PLAN.md
first — it's the authoritative work breakdown for adding options/LEAPS
support across tws_api and trading_hub, verified against this codebase on
2026-09-11. This prompt only concerns the tws_api-side slice of that plan
(its "Work breakdown" items 1-3, "Suggested sequencing" items 1-3); the
trading_hub-side slice (item 4) is a separate handoff for that app's own
session once this is done.

The plan's own "Reference-material gap" section is now resolved — a
current IBKR TWS API bundle (twsapi_macunix.1045.01.zip,
server_versions.py through v223) is unzipped at
`ibkrpubsub/ib_src/IBJts/source/pythonclient/ibapi/`; confirm it's still
there and still the source you're reading from before starting. Do not
implement any new wire-format field from memory or from IBKR's
Doxygen-style property docs alone — this codebase has already shipped
real field-order/field-presence bugs from doing that (a placeOrder
field-shift, a missing manualOrderTime, and — this week — OpenOrder and
ExecDetails decoders that read as unconditional in source but were
blank-and-stripped on the real wire for certain shapes, only caught by
comparing against an actual captured frame). See this repo's own
tws_api/CLAUDE.md "Reference material" section for the full reading
procedure (which EClient method to read, how to cross-reference
MIN_SERVER_VER_* gates against this library's negotiated server_version)
— treat clean source-reading as necessary but not sufficient; verify
against real captured frames wherever practical, not just this bundle's
code.

Implement, in this suggested order (matching OPTIONS_LEAPS_PLAN.md's own
"Suggested sequencing"):

1. Contract resolution: Requests.req_contract_details/2 (encode
   reqContractDetails, msg id 9, for an option: symbol/expiry/strike/
   right/multiplier/exchange) + decode ContractDetails (id 10) and
   ContractDetailsEnd (id 52) in MessageParser/Messages. This unblocks
   everything else — a symbol+expiry+strike+right combination is
   ambiguous without resolving it to a con_id first (a well-known IBKR
   gotcha the plan doc calls out). Handle multiple ContractDetails
   replies per request (an underspecified query can match more than one
   contract) with careful request-id correlation.

   Even though the reference source shows this message's fields as
   unconditionally present, verify the resulting decode against a real
   captured ContractDetails frame before trusting it — the same
   discipline already forced on OpenOrder and ExecDetails this week
   after each was shipped from source-reading alone and later found
   wrong on real data.

   Optionally also add req_sec_def_opt_params/2 (id 78) + decode
   SecurityDefinitionOptionParameter (id 75) and its terminator
   SecurityDefinitionOptionParameterEnd (id 76) — lets a caller ask "what
   expiries/strikes exist for this symbol" instead of already knowing
   them. Nice-to-have, not required for the rest of this work.

2. Option order placement: generalize Requests.place_order/2 to accept
   :sec_type/:expiry/:strike/:right/:multiplier instead of the current
   hardcoded sec_type: "STK" (see that function's own moduledoc "Scope
   and known gaps" section, which already documents this as a known
   limitation). This is a real field-order-sensitive change — every
   field you add or change must be byte-diff-verified against the
   reference client per tws_api/CLAUDE.md's mandate, not shipped from
   memory. Multi-leg combo orders (comboLegs, vertical spreads etc.) are
   explicitly OUT OF SCOPE for this change — single-leg options only.

3. Option market data: decode TickOptionComputation (msg id 21) —
   implied vol, delta, gamma, vega, theta, and the option's/underlying's
   price. Plain TickPrice/TickSize continue to work for bid/ask/last on
   the option contract itself; greeks only ever arrive via this message
   type. No change needed to reqMktData's own encoding — confirm this
   against the current reference client before assuming it (the plan
   doc's claim is that trading_hub's existing sec_type-override plumbing
   already covers non-blank expiry/strike/right once trading_hub's own
   side is extended, a separate app's work item, not this one).

When done:
- Run mix compile --warnings-as-errors and mix test.
- Update OPTIONS_LEAPS_PLAN.md's "Current state" section to reflect what
  actually shipped (which message ids/functions, any deviations from the
  plan discovered while implementing).
- Do NOT implement trading_hub's side (contract/subscription/order
  plumbing, item 4 of that plan) from this session — hand that off as
  its own prompt for trading_hub's session once this lands, per this
  workspace's cross-app boundary rule.
- Report back: what shipped, what's still open, and which decoded fields
  (if any) were verified against a real captured frame vs. source-reading
  alone.
```

## After this lands

Two follow-up handoffs, each for that app's own session (not from here):

1. **`trading_hub`**: `OPTIONS_LEAPS_PLAN.md` work-breakdown item 4 —
   contract/subscription/order plumbing built on top of the above.
2. **`trading_options_sim`** (this app, this session, once `trading_hub`'s
   side also lands): swap `ContractMonitor`'s pricing backend from
   `TradingOptionsSim.Pricing.BlackScholes` to a real-quote backend per
   `OPTIONS_SIM_ARCHITECTURE_PLAN.md` §5a's v2 — the rule-evaluation
   snapshot interface is designed not to change shape when this happens.
