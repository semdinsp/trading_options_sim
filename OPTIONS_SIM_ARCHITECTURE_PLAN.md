# trading_options_sim — Architecture Plan

Status: planning only, no code written yet.
Scope: this document covers `trading_options_sim` only. Where it needs a
change on `trading_system`'s or `trading_hub`'s side, that's called out
explicitly and handed off as a prompt for that app's own Claude Code
session per this workspace's cross-app boundary rule — nothing here
proposes editing those apps directly.

## Goal

Build `trading_options_sim` as a paper-trading simulator for **options**
(including LEAPS — see `../OPTIONS_LEAPS_PLAN.md`, they're not a separate
wire concept, just options with a longer-dated expiry) that reuses three
patterns already proven elsewhere in this workspace, adapted for options:

1. **`trading_live`'s per-symbol monitor pattern** — one supervised
   GenServer per traded instrument, not per strategy.
2. **`trading_system`'s strategy/version/lifecycle concept** — versions are
   immutable, lifecycle stage is tracked independently of trading logic.
3. **`trading_live`'s promotion-by-version-id flow** — pull a specific
   `StrategyVersion` out of `trading_system` by id and freeze a local
   snapshot from it, rather than living against a mutable remote reference.
4. **`trading_system`'s discovery/quarantine/target-pool concepts**,
   reused as-is for the stage model and target scoping, extended for an
   options identity.

The result is architecturally a sibling of `trading_live`, not a fork of
it — `trading_live` places *real* IBKR orders against promoted equity
strategies; `trading_options_sim` places *simulated* orders against
promoted (or independently authored) options strategies. Where the two
diverge, this doc says so explicitly.

## Why not just extend `trading_live` for options?

Considered and rejected. `trading_live`'s `StrategyStockMonitor` (see that
module's moduledoc) hardcodes a stock-shaped identity (`symbol` string,
`TradingHub.IBKR.Client.place_order/1` for real fills) throughout — a
`{symbol, expiry, strike, right}` 4-tuple identity and a
paper/simulated-fill loop are different enough concerns that bolting them
onto the existing monitor would mean threading an `is_option?`/`simulated?`
branch through nearly every clause of an already-large GenServer
(`strategy_stock_monitor.ex` is ~2600 lines). A separate app matches how
`trading_live` itself is already separate from `trading_system` — same
promotion-by-id relationship, new app boundary.

## 1. Contract identity

An option position cannot be identified by ticker alone (same underlying,
different strike/expiry are different instruments — this is already flagged
as an open gap in `../OPTIONS_LEAPS_PLAN.md`'s step 4). Every schema and
process key in this plan uses a `contract_key` built from:

```elixir
%{
  symbol: "AAPL",           # matches tws_api's ContractDetails.symbol —
                             # deliberately NOT "underlying"; see below
  expiry: "20270115",       # matches tws_api's raw wire format
                             # (YYYYMMDD string), NOT a ~D[...] Date
  strike: Decimal.new("150.00"),  # the one deliberate exception — see below
  right: "C" | "P"
}
```

**Naming adopted from `tws_api`/`trading_hub`, confirmed 2026-09-13**:
originally drafted with this app's own vocabulary (`underlying`, a
`Date` `expiry`), independently designed from `tws_api`'s real
`ContractDetails` struct (`symbol`, `sec_type`, `expiry`, `strike`,
`right`, `exchange`, `currency`, ... — see `tws_api/lib/tws_api/messages.ex`).
A `tws_api` session flagged the mismatch while reviewing this plan
against its now-shipped `ContractDetails` decode. Decision: adopt
`tws_api`'s field names and wire-format `expiry` string directly, rather
than inventing a second vocabulary this app would need to translate at
every `trading_hub`/`ib_portfolio` boundary crossing. `symbol` here means
the option contract's own underlying ticker, same as every other
`symbol` field already flowing through this workspace's `PubSub`
messages/`ib_portfolio.Message` — not the option contract's own
(rarely-used) `local_symbol`.

**`strike` is the one deliberate exception, kept as `Decimal`, not
`tws_api`'s plain `float`** (confirmed 2026-09-13): this app's own
`trading_core`-based math (`PositionSizing`/`RiskControls`/`ExitStrategy`,
§4c's future `TRADING_CORE_OPTIONS_UPDATE_PROMPT.md` work) is `Decimal`-only
throughout, and a `float` strike risks classic floating-point
equality/comparison bugs wherever a rule or lookup needs to match a
specific strike exactly. Convert `Decimal` ↔ `float` only at the
`IBKRLive` pricing-backend adapter boundary (§5a v2) when calling into
`tws_api`-derived data — never carry a raw `float` strike through this
app's own schemas or `ContractMonitor` state.

Serialized as a stable string (`"AAPL:20270115:150.00:C"`, matching the
wire-format expiry above) wherever a single string key is needed
(Registry name, PubSub topic suffix, map key). A resolved IBKR `con_id`
is stored alongside once available but is **not** part of the identity —
mirrors `tws_api`'s contract-resolution plan (`../OPTIONS_LEAPS_PLAN.md`
step 1): con_id is an enrichment, not the key, so the sim can carry a
contract before/without ever resolving it against TWS (this app doesn't
need a live IBKR connection to run — see §5).

**This is a deliberate divergence from `trading_hub`, not an oversight**
(confirmed 2026-09-13, `trading_hub`'s options work — PR #101 — landed
with `TradingHub.IBKR.ContractResolver`, resolving `(symbol, expiry,
strike, right)` to a cached `con_id` that becomes *the* runtime key
everywhere downstream there — `Order.contract_id`, `Position.contract_id`,
subscriptions). `trading_hub` can make `con_id` its real key because it
always has a live TWS connection and must place real orders against
IBKR's actual identity system; this app has neither constraint (§7: no
real order placement) and must be able to carry/simulate a contract with
no IBKR connection at all, so `contract_key`'s 4-tuple stays the
identity here, `con_id` stays an optional enrichment. When v2 (§5a)
consumes `trading_hub`'s relay, `con_id` is useful for correlating a
quote back to the exact contract `trading_hub` resolved, but never
becomes this app's own key.

## 2. Schema: Strategy / StrategyVersion / lifecycle

Reuse `trading_system`'s shape directly, not reinvented:

```
TradingOptionsSim.Sim.Strategy
  - id (UUIDv7), name, notes, asset_class ("options", fixed)

TradingOptionsSim.Sim.StrategyVersion
  - id (UUIDv7), strategy_id, version (integer)
  - params, rules, usage_conditions, position_sizing (maps — same
    "immutable, fork instead of edit" contract as trading_system's)
  - direction ("long" | "short")
  - option_leg_config: %{
      "right" => "C" | "P" | "either",   # "either" = rules pick per-signal
      "expiry_selection" => "fixed" | "dte_target" | "leaps",
      "dte_target_days" => integer | nil,   # e.g. pick nearest expiry to 45 DTE
      "fixed_expiry" => ~D[] | nil,
      "strike_selection" => "fixed_delta" | "fixed_strike" | "pct_otm",
      "target_delta" => Decimal | nil,      # e.g. 0.30 delta for a target-delta strategy
      "multi_leg" => false | %{"structure" => "vertical" | "iron_condor" | ...}
    }
  - lifecycle_stage ("discovery" | "quarantine" | "test_portfolio" | "retired")
  - quarantine_started_at, quarantine_trading_days, quarantine_last_counted_date
  - promoted_to_live_app, promoted_to_live_strategy_id, promoted_to_live_at
    (set when a test_portfolio-stage version is promoted OUT to
    trading_live-or-equivalent for real execution — see the note below;
    lifecycle_stage itself never becomes "live" here, this app doesn't
    have that stage)
  - parent_version_id, generation (fork lineage — same as trading_system)
  - target_pool_id
  - source: "native" | "promoted_from_trading_system"
  - source_trading_system_version_id (nil for "native")
  - promoted_at, promoted_snapshot (frozen copy of the trading_system
    version's own params/rules at promotion time, when source is
    "promoted_from_trading_system" — see §4's history: this direction
    was abandoned once the real requirement was clarified as
    trading_live pulling FROM this app, not this app pulling from
    trading_system. These fields exist in the schema but every version
    today is "native" — see §4 for the corrected design.)
```

`multi_leg` is included in the schema now (so the column/shape exists) but
explicitly **out of scope for v1 execution** — see §7. A single-leg
long-call/long-put/covered-style version is the initial target; the field
exists so a later iron-condor/vertical-spread simulator doesn't need a
schema migration to retrofit it.

**Three stages, not `trading_system`'s five** — `discovery -> quarantine
-> test_portfolio`, plus terminal `retired`. No `live` stage in this app
at all: `trading_options_sim` never places a real order (§7), so "live"
isn't a state this app's own lifecycle needs to represent — going live
means handing a proven version off to `trading_live`, or an
options-capable equivalent of it, as a **separate app boundary**, the same
way `trading_system`'s own versions don't try to model `trading_live`'s
execution state either. `test_portfolio` is this app's terminal
"proven, ready to hand off" stage — the promotion-out event (see below)
fires from `test_portfolio`, mirroring `trading_system`'s own rule that
only `quarantine` (its last non-live stage before the boundary) is a
valid promotion source.

Same transition rules otherwise (fork/retire frozen during
`quarantine`/`test_portfolio`, `retired` is unretireable back to
`discovery`) — this is a proven, already-debugged state machine (see
`LIFECYCLE.md`'s incident history: the `discovery -> retired` gap, the
`test_portfolio -> live` shortcut closure that `trading_system` itself
had to walk back). Port the module (`lifecycle_stage_changeset/2` and its
transition-validation logic) nearly verbatim minus the `live` stage and
its transitions, swapping `StrategyRun`/`StrategyPerformanceSnapshot`
associations for this app's own run/fill schemas (§6).

**Promoting a `test_portfolio` version to real execution** is an
outbound cross-app call, structurally the mirror image of §4's inbound
promotion: `TradingOptionsSim.Sim.promote_to_live_app/2` stamps
`promoted_to_live_app`/`promoted_to_live_strategy_id`/`promoted_to_live_at`
on the local version (lifecycle_stage stays `test_portfolio` — same
"promotion is a marker, not a stage advance" pattern
`trading_system.promote_strategy_version(version, "live")` already uses,
per `LIFECYCLE.md`'s note that `promoted_to_live_at` doesn't move
`lifecycle_stage`) and fires a fire-and-forget notification to whichever
app is consuming it. This app doesn't know or care what that consumer
looks like yet — `promoted_to_live_app` is a plain string precisely so
the target isn't hardcoded to `trading_live` (an options-capable
execution app may not exist yet; see the Open Questions below).

**Difference from trading_system**: no `QuarantineEligibilityWorker`
auto-promotion in v1 — start with manual-only `discovery -> quarantine`
promotion via API/UI, matching the "manual" path `LIFECYCLE.md` already
documents as a first-class option. Add the automatic daily-worker path
later once there's a real closed-run history to threshold against (same
sequencing risk `trading_system` itself had to solve for).

## 3. Target pools, adapted for options

Reuse `TargetPool`'s shape (`name`, `region`, `inverse`, soft-delete) as
the scoping container, but `TargetPoolMember` is fundamentally different
because a stock target pool member holds a symbol/exchange/currency,
while an options target needs the identity in §1 plus the equity
underlying's own trading metadata:

```
TradingOptionsSim.Sim.TargetPool
  - same fields as trading_system's TargetPool (name, description,
    region, inverse, deleted_at)

TradingOptionsSim.Sim.TargetPoolMember
  - target_pool_id
  - symbol, exchange, currency (the equity underlying's own identity —
    plain field names, matching trading_live's own TargetPoolMember and
    tws_api's ContractDetails.symbol convention rather than an
    "underlying_" prefix; see §1's naming note for why. This member
    row's "symbol" is always an equity underlying, never itself an
    option contract — no prefix is needed to disambiguate that within
    this schema)
  - ib_conid (nil until resolved — see §5)
  - contract_selection: same shape as StrategyVersion.option_leg_config's
    expiry/strike selection fields, OR nil to inherit the version's own
    option_leg_config unchanged. Exists for the case where two versions
    share a pool of underlyings but want different strike/expiry rules
    per version — nil (inherit) is expected to be the common case.
```

A pool member identifies the **underlying** (AAPL, not a specific option
contract) — the specific `contract_key` (§1) is resolved per-monitor at
activation time by combining a pool member's underlying with the active
`StrategyVersion.option_leg_config`. This mirrors `trading_system`'s own
member/version split (`TargetPoolMember` is underlying-agnostic re:
strategy config; a version scopes itself to a pool, not the reverse) and
means the same "S&P mega-cap tech" pool can back both a "45 DTE, 0.30
delta calls" version and an "LEAPS, 1-year, 0.70 delta" version without
duplicating pool membership.

**Discovery and quarantine against target pools** (the user's stated
requirement): identical mechanism to `trading_system`'s — a
`StrategyVersion.target_pool_id` scopes which underlyings this version's
`EntryEvaluator`-equivalent considers, and quarantine/lifecycle transitions
operate on the version, independent of which pool it's scoped to. No new
concept needed here beyond what's already in §2; pools don't have their
own lifecycle, only versions do (matches `trading_system` exactly).

## 3a. Tagging

Both `trading_system` (`TradingSystem.Trading.Tag`) and `trading_live`
(`TradingLive.LiveTrading.Tag`) already implement the identical pattern
independently — ad-hoc, human-invented labels (e.g. "no exit", "needs
review") for filtering/grouping during testing and review, deliberately
**not** part of a version's trading config/lifecycle. `trading_system`'s
own moduledoc calls this out explicitly: "a sibling app (`trading_live`)
implements the identical pattern... no shared tag pool between the two;
each app's tags are its own." `trading_options_sim` should follow the
same precedent — its own local, independent tag pool, not shared with
either sibling:

```
TradingOptionsSim.Sim.Tag
  - id (UUIDv7), name (globally unique, trimmed, upserted by exact
    string match — same "no case-folding" scope cut trading_system's
    get_or_create_tag/1 already made), description

  many_to_many :strategy_versions, through: StrategyVersionTag
```

`StrategyVersionTag` is the bare join table (`strategy_version_id`,
`tag_id`), matching `trading_system`'s `StrategyVersionTag`. Wire the
same `on_replace: :delete` `many_to_many` on `StrategyVersion` (§2) that
`trading_system`'s `StrategyVersion`/`trading_live`'s `LiveStrategy` both
use, and a `get_or_create_tag/1` + `put_strategy_version_tags/2` context
pair mirroring `trading_system.Trading`'s own functions of the same
shape. No lifecycle-stage guard on tagging (same as both siblings) — a
tag is workflow commentary, not trading config, so it stays editable
through `quarantine`/`test_portfolio` the same way a version's `notes`/
`rating` do (§2's lifecycle port already carries that same "deliberate
exception, no stage guard" precedent for `notes_changeset/2`/
`rating_changeset/2`).

**On promotion (§4) and promote-out (§2's `promote_to_live_app/2`)**: tags
are workflow-local, not part of either frozen snapshot — a version's tags
here are never copied to/from `trading_system`'s tags on the source
version, and never handed to `trading_live` on promote-out, matching
`trading_system`'s own moduledoc note that each app's tag pool is
independent. An operator re-tags in each app separately if useful there.

## 4. Promotion: `trading_live` pulls from `trading_options_sim` (going live with real money)

**Corrected twice, 2026-09-13** — first draft described pulling a
version *in* from `trading_system` (wrong direction, misread the
original request). Second draft described `trading_options_sim` pushing
*out* to `trading_live` (still wrong — doesn't match the real,
already-working precedent). **Verified directly against
`trading_live/lib/trading_live/live_trading.ex:47-64`
(`LiveTrading.promote_version/1`) before writing this**: promotion is a
**pull initiated by the destination app**. `trading_live` itself calls
OUT to `trading_system`'s `/api/v1` (`Client.get_version/1`,
`Client.get_strategy/1`, then fire-and-forget
`Client.mark_promoted/1`/`Client.link_to_live_strategy/2`) and builds
its *own* local `LiveStrategy` row from the response.
`trading_system` never calls `trading_live` — it stays a passive
source, only ever responding to `trading_live`'s own requests.

The analogous design here: a strategy is authored and gated *inside*
`trading_options_sim` (discovery → quarantine → test_portfolio, §2).
Once it reaches `test_portfolio`, **`trading_live` (or a future
options-capable execution app) pulls it** — calling this app's own
`/api/v1` (already built, §4a/step 5) to fetch the version, then
recording the link back here via a new inbound endpoint, mirroring
`trading_system`'s `link_trading_live`/`unlink_trading_live` shape:

```
POST /api/v1/versions/:id/link_live_strategy   {"live_strategy_id": "..."}
POST /api/v1/versions/:id/unlink_live_strategy
```

`trading_options_sim` implements only the **passive/inbound** side —
these two endpoints plus the read routes the pull already needs
(`GET /api/v1/versions/:id`, already built). It does **not** implement
any outbound client that calls `trading_live` — that HTTP client
(`TradingLive.TradingOptionsSim.Client`-equivalent) and its own
`promote_version`-shaped orchestration function belong entirely inside
`trading_live`'s own app, the same way `TradingLive.TradingSystem.Client`
lives in `trading_live`, not in `trading_system`. Building that piece is
out of scope for this app's own session — see the handoff prompt below.

**Schema note**: §2's `promoted_to_live_app`/`promoted_to_live_strategy_id`/
`promoted_to_live_at` fields and `Sim.promote_to_live_app/3` were built
under the earlier (incorrect) push-model assumption — an operator/agent
triggering the marker from *this* app's own side. Under the corrected
pull model, the marker should instead be written by the new
`link_live_strategy` endpoint above, called *by* `trading_live` after it
successfully builds its own local record — same fields, same "marker,
not a stage advance" semantics (`lifecycle_stage` stays `test_portfolio`,
matching `trading_system`'s own `promoted_to_live_at` precedent), just
triggered from the other direction. `Sim.promote_to_live_app/3` needs no
signature change for this — only its caller changes, from "an operator
action inside this app" to "the controller action backing
`link_live_strategy`, invoked by `trading_live`'s pull."

**Real blocker, confirmed 2026-09-13, not yet started anywhere**:
`trading_live` cannot execute an options strategy today —
`TradingLive.StrategyStockMonitor` (the only execution engine that app
has) is stock-shaped throughout (a `symbol` identity,
`IBKR.Client.place_order/1` assuming `sec_type: "STK"`), and while
`trading_hub`'s own `Order`/`Position` structs now carry
`:sec_type`/`:expiry`/`:strike`/`:right`/`:multiplier` (PR #101), that
path is untested end-to-end for a real option order. This pull-based
promotion cannot be usefully built until `trading_live` (or a new
options-aware execution app) actually has somewhere to route an option
order — track as a prerequisite for that app's own future work, not
something to build in parallel here.

**Handoff prompt for `trading_live`'s own session** (do not implement
from here, per this workspace's cross-app boundary rule): once
`trading_live` gains real option-order execution, its session should
build a `TradingOptionsSim.Client` (mirroring its own existing
`TradingSystem.Client`) plus a `promote_options_version/1`-shaped
orchestration function, pulling from this app's `/api/v1` the same way
`LiveTrading.promote_version/1` already pulls from `trading_system`.

**Native-only for now**: every `StrategyVersion` in this app today is
authored natively. `source`/`source_trading_system_version_id`/
`promoted_at`/`promoted_snapshot` were built for an earlier,
now-abandoned trading_system-promotion-in design and are currently
unused — left in place rather than migrated out immediately, since that
direction could still be worth revisiting later if a concrete need
appears (see Open Questions).

## 4a. REST API + MCP access (`anubis_mcp`)

Both `trading_system` and `trading_live` expose the same two access
surfaces over the same auth primitive, and `trading_options_sim` should
too — this is what makes §4's promotion-in and the future promote-out
(§2) plumbing possible at all, and what lets an operator or an agent
(Claude Code, `CLAUDEDAILY.md`-style daily loop) drive this app the same
way they already drive its two siblings.

**Dependency**: add `{:anubis_mcp, "~> 2.0"}` to `mix.exs` — same pinned
major version `trading_system`/`trading_live` already use.

**Auth primitive — `TradingOptionsSim.Sim.ApiToken`**, ported from
`trading_system/lib/trading_system/trading/api_token.ex` nearly verbatim:
a scoped, revocable Bearer token (`:crypto.strong_rand_bytes/1` +
SHA-256 hash, raw value shown exactly once at creation), independent of
any session-cookie LiveView auth. Scopes for this app's own domain:

```
strategies:read   strategies:write
target_pools:read target_pools:write
tags:read         tags:write
runs:read
mcp:read          mcp:write
```

One token type backs **both** surfaces below — same precedent
`trading_system`'s own `ApiToken` already sets (its `/api/v1` plug and
its `TokenValidator` for MCP both check the same table).

**REST API — `/api/v1`, as built** (see `lib/trading_options_sim_web/router.ex`):

```
GET    /api/v1/strategies                              strategies:read
GET    /api/v1/strategies/:id                          strategies:read
POST   /api/v1/strategies                              strategies:write
POST   /api/v1/strategies/:id/versions                 strategies:write
GET    /api/v1/versions/:id                            strategies:read
POST   /api/v1/versions/:id/promote                    strategies:write   (discovery->quarantine, quarantine->test_portfolio, retired->discovery)
POST   /api/v1/versions/:id/downgrade                  strategies:write   (->retired, or test_portfolio->quarantine)
POST   /api/v1/versions/:id/promote_to_live_app        strategies:write   (§4's marker — corrected 2026-09-13: now called
                                                                            BY the pulling app, e.g. trading_live, after it
                                                                            builds its own local record — see §4's rewrite;
                                                                            not yet renamed to link_live_strategy in code)
PUT    /api/v1/versions/:id/tags                       tags:write         (replace full tag set)
POST   /api/v1/versions/:id/tags                       tags:write         (get-or-create by name, union onto existing)
GET    /api/v1/target_pools                            target_pools:read
GET    /api/v1/target_pools/:id                        target_pools:read
POST   /api/v1/target_pools                            target_pools:write
POST   /api/v1/target_pools/:id/members                target_pools:write
GET    /api/v1/tags                                    tags:read
```

**Not yet renamed following §4's correction**: the endpoint is still
`promote_to_live_app` in code, matching its original (push-model)
design — §4's corrected pull model means `trading_live`'s own session
should call this endpoint once it has already built its own local
record, passing its own `live_strategy_id`. Renaming to
`link_live_strategy`/adding `unlink_live_strategy` (matching
`trading_system`'s own naming) is a small follow-up, not done yet.

Same auth plug shape as `trading_system`'s (`TradingSystemWeb.ApiAuthPlug`
equivalent) — Bearer token looked up by hash, scope-checked per route,
`last_used_at` stamped.

**MCP server — `TradingOptionsSim.MCP.Server`**, mounted at `/mcp` exactly
like `trading_system`'s (`forward "/mcp",
Anubis.Server.Transport.StreamableHTTP.Plug, server:
TradingOptionsSim.MCP.Server` in the router), same `Anubis.Server`
declaration shape:

```elixir
use Anubis.Server,
  name: "trading_options_sim",
  version: "1.0.0",
  capabilities: [:tools],
  authorization: [
    authorization_servers: [@mcp_resource_url],
    resource: @mcp_resource_url,
    realm: "trading_options_sim",
    scopes_supported: ["mcp:read", "mcp:write"],
    validator: {TradingOptionsSim.MCP.TokenValidator, []}
  ]
```

Tool set, as built — each a thin wrapper around a `Sim` context function
(mirrors `trading_system.MCP.Server`'s "thin wrapper around
already-existing, already-tested context functions" posture) — read
tools need no scope beyond a valid token, write tools require
`scopes: ["mcp:write"]` on the component:

```
list_strategies      get_strategy         list_target_pools
get_target_pool       list_tags
---
create_strategy       promote_version      downgrade_version
add_strategy_version_tag
```

Not yet built as MCP tools (REST-only today): `create_strategy_version`,
`promote_to_live_app`, `set_strategy_version_tags` (the full-replace
variant — only the get-or-create-by-name `add_strategy_version_tag`
exists as an MCP tool). Small follow-ups, not started.

`TradingOptionsSim.MCP.CallGuard` ported the same way — bounded
`Task.async/yield` timeout wrapper around every tool body (a hung `Repo`
call must never block an MCP session indefinitely) plus the
per-token-and-tool rate limiter, **including** the fix already learned
the hard way on `trading_system`'s side: the rate-limit ETS table needs a
permanent supervised owner (`CallGuard.TableOwner`, started under
`TradingOptionsSim.Application`), not a lazily-created table inside a
request process — `trading_system`'s own `CallGuard` moduledoc documents
a real incident (confirmed live: every one of 46 real MCP calls saw
`count: 1`, the rate limit silently never limited anything for months)
from getting this wrong the first time. No reason to re-learn that bug
in a third app.

**Where this plugs into the rest of the plan**: §4's `TradingOptionsSim.
TradingSystem.Client` is this app calling *out* to `trading_system`'s
existing `/api/v1`; this section is what lets `trading_system` (or an
operator, or an agent) call *into* `trading_options_sim` the same way —
both directions use the identical Bearer-token-over-REST pattern, and
both apps additionally expose the MCP surface for agent-driven operation
(promoting versions, checking quarantine status, tagging) without
needing a browser session.

## 4b. Settings page (`/settings`)

Mirrors `trading_system`'s `TradingSystemWeb.SettingsLive` shape — one
LiveView holding every app-wide operator setting, with the §4a token
management living there rather than a separate page, matching
`trading_system`'s own layout (that LiveView's own moduledoc lists "API
token — manages one designated token by label" as one section among
several).

**Token management section** — ported behavior, not just the ApiToken
schema itself:

- One designated **outbound-promotion token** (label e.g.
  `"trading-options-sim-to-trading-system"`, scopes
  `strategies:read target_pools:read` — what §4's `TradingSystem.Client`
  needs to call *into* `trading_system`). Same single-token-per-label
  "roll" model as `trading_system`'s own `@token_label` section: rolling
  revokes the current token and issues a new one, raw value shown once
  (60s display window, then hidden — `@rolled_token_display_ms` ported
  as-is) and copied to clipboard on mount via the same
  `JS.dispatch("app:copy-rolled-token", ...)` pattern. This is
  **trading_options_sim's own copy of a token issued by trading_system**
  — an operator generates it on `trading_system`'s `/settings` page and
  pastes the raw value in here; this app has no ability to self-issue a
  token against a remote app it doesn't control.
- A **list of inbound tokens** this app has issued to callers (mirrors
  `trading_system`'s `@mcp_tokens`/`ApiToken.active_with_scope/1`
  section) — one row per token with label/scopes/created/last-used,
  a create form (label + read/write checkboxes, matching
  `to_form(%{"label" => "", "read" => true, "write" => false}, as:
  "mcp_token")`), and a revoke action per row. Covers both REST-only
  callers (an operator's `curl`/script) and MCP callers (Claude Code,
  a daily-loop agent) — same token type backs both per §4a, so one list
  suffices; no separate "MCP tokens" vs. "API tokens" section is needed
  the way `trading_system`'s page currently splits them (that split
  predates `mcp:read`/`mcp:write` unifying with the REST scope set —
  no need to reproduce a distinction this app never had).
- **`trading_system_api_base_url`** (where §4's Client points) as a
  plain settings field alongside the token — an operator sets both
  together when connecting the two apps.

Other settings sections on this same page, ported/adapted from
`trading_system`'s (`AppSettings`, same schema-shape precedent):
lifecycle thresholds (§2's quarantine days/min-trades/min-PnL, once those
move from hardcoded defaults to operator-configurable — see this plan's
Open Questions), and (once built, §7) the pricing-model config for §5a's
Black-Scholes pricer (flat IV assumption, slippage/spread bps).

## 4c. `ib_portfolio` — the trading_hub connectivity primitive

`../ib_portfolio` is a shared, zero-Phoenix-dependency library already
extracted from `trading_dashboard`'s and `trading_risk`'s independently
(and near-identically) written hub-connection GenServers — see its own
`HubClient` moduledoc. Both apps depend on it as a sibling `path:` dep
(`{:ib_portfolio, path: "../ib_portfolio"}`); `trading_options_sim` should
do the same rather than hand-rolling its own connect/reconnect/erpc loop
a third time, which is exactly the duplication this library exists to
prevent. This **replaces** the placeholder `TradingOptionsSim.HubMonitor`
name used elsewhere in this doc (§4a's `hub_connected?` sketch,
§9's original gap list) — that process is `IbPortfolio.HubClient` itself,
started under this app's own supervision tree, not a new module to write
from scratch.

**What it provides, and how this app uses each piece:**

- **`IbPortfolio.HubClient`** — one GenServer, started per this app with
  its own name/topics, e.g.:

  ```elixir
  {IbPortfolio.HubClient,
   name: TradingOptionsSim.HubClient,
   hub_node: Application.get_env(:trading_options_sim, :hub_node),
   topics: ["prices:*"],
   forward_to: TradingOptionsSim.PriceRelay}
  ```

  Handles the connect/reconnect-with-backoff loop against `trading_hub`'s
  distributed `Phoenix.PubSub`, subscribes to the underlying-price fan-out
  topic (`"prices:all"`, via the `"prices:*"` wildcard expansion — see
  `expand_wildcard_topic/1`), and forwards every received message plus
  `{:hub_connection_status, boolean}` transitions to `forward_to`.
  `TradingOptionsSim.PriceRelay` (a new, small GenServer this app does
  need to write) is the `forward_to` recipient: it re-broadcasts each
  underlying tick onto this app's own **local** `TradingOptionsSim.PubSub`
  as `"prices:" <> symbol` (the underlying's `symbol`, per §1's naming
  convention), which is what `ContractMonitor`
  (§5) actually subscribes to — mirroring how `trading_live`'s own
  monitors read from the hub relayed onto a local bus rather than every
  monitor independently managing hub connectivity. One `HubClient` for
  the whole app, not one per contract.

- **`IbPortfolio.Message.to_topic/1`/`is_message?/1`** — used inside
  `PriceRelay` to recognize `%TradingHub.Message{type: :price}` structs
  arriving from `HubClient` and derive/confirm the topic, instead of
  re-deriving that logic locally (a third independent copy of what
  `trading_dashboard`/`trading_risk` already extracted this to prevent).

- **`IbPortfolio.OrderParams`** — **not used in v1.** This app places no
  real orders (§7); `OrderParams.build/1`/`from_form/4` exist to
  normalize a caller's params for `TradingHub.Orders.Manager.submit_order/1`,
  which only this app's own eventual "promote to live app" boundary (§2)
  would ever call, and only if that boundary target turns out to be a
  `trading_hub`-backed execution app rather than something else (open
  question in §2). Worth knowing this module exists and already solves
  the action/order_type/quantity type-coercion bugs `trading_live`/
  `trading_dashboard` each hit independently, in case that day comes —
  no reason to use it before there's a real order to place.

**Status extension update**: `TradingOptionsSim.StatusExtension.hub_connected?/0`
(§4b's Settings-adjacent health reporting) should check
`IbPortfolio.HubClient.connection_status(TradingOptionsSim.HubClient).connected`,
guarded by the same `Process.whereis/1` check `trading_live`'s own
`StatusExtension.hub_connected?/0` uses — not a bespoke `GenServer.call(pid,
:connected?)` against a from-scratch process, since `HubClient` already
exposes `connection_status/1` for exactly this.

## 4d. UI style — adhere to this app's own `DESIGN.md`

`trading_options_sim/DESIGN.md` already exists in this app (confirmed
2026-09-13) — a "Dark Pool" terminal design system: single hardcoded dark
DaisyUI theme (no light mode/toggle), `Oswald` for headings/labels/nav,
`JetBrains Mono` (`.font-data`) for every number/price/timestamp/payload,
hard edges (no rounded corners), borders instead of shadows, bordered-
rectangle badges (never DaisyUI's pill `badge-*` fills), a `Layouts.trading_navbar`/
`Layouts.trading_live` layout pair, and a fixed empty-state pattern. Note:
its own examples (`portfolio_monitor_live.ex`, "Message Monitor") name
LiveViews that don't exist in this app yet — it reads as carried over
from a sibling app's dashboard as this app's starting design language,
not (yet) validated against a real `trading_options_sim` screen. Treat
the *rules* (typography roles, color-token usage, surface/shape,
badge/empty-state patterns, "When adding a new screen" checklist) as
binding for every LiveView this plan calls for; don't carry over the
specific component names it references until they exist here too.

**Where this plan's own future screens must follow it:**

- **§4b's Settings page** (`/settings`) — token list/create-form rows,
  the outbound-token panel, and any lifecycle/pricing-config sections all
  go through this theme: `font-data` on every token value/timestamp,
  bordered-rectangle status badges (active/revoked, connected/
  disconnected) rather than pill badges, hard-edged panels separated by
  `border-base-300`, no drop shadows.
- **Any future monitor-style dashboard** for `ContractMonitor` state
  (§5) — a live, dense, `Layouts.trading_live`-wrapped screen showing
  per-contract snapshots (price, greeks, position, pending sim-fill) is
  the natural UI for this app's own "monitors" concept, structurally the
  same three-zone pattern (`header → stats/filter strip → scrollable
  content`) `DESIGN.md`'s "Layout patterns" section already specifies for
  `trading_live`'s own monitor screens. `.signal-dot`/`.row-flash` are
  the existing motion primitives for "hub connected" and "new sim fill
  arrived," respectively — reuse them rather than inventing new
  animations, per `DESIGN.md`'s own motion-is-for-liveness rule.
- Direction badges (long/short) use the existing `text-long`/`text-short`
  custom tokens, not the success/error P&L tokens — relevant here since a
  long call and a short put can both show positive unrealized P&L at the
  same time; keep those two concepts visually distinct the same way
  `DESIGN.md` already mandates for equities.

No new design system to invent — this is an adopt-as-is, not a
starting-point-to-diverge-from.

## 5. Per-contract monitor (the "monitors" pattern)

**Event-driven by construction, deliberately not `trading_system`'s
poll/worker style** (confirmed direction, 2026-09-13): `trading_system`'s
own entry/exit path is a fixed-interval tick loop
(`TradingSystem.Trading.EntryEvaluator`, run on a timer) that periodically
queries candidate versions and enqueues `Oban.Worker` jobs to act on
them — a batch/poll model, correct for that app's actual needs (backtest-
style paper simulation across a large universe, no real-time order
latency to protect) but not what `trading_options_sim` should copy. Each
`ContractMonitor` below is instead a live subscriber that reacts the
instant a relevant tick/signal broadcast arrives on its own local PubSub
subscription (§4c) — the same responsiveness property `trading_live`'s
`StrategyStockMonitor` already has, and the reason this plan's §"Why not
just extend `trading_live`" chose that app's monitor pattern as the model
in the first place rather than `trading_system`'s. Nothing in this
section should be read as introducing a polling loop anywhere in the hot
path; a periodic worker is acceptable only for things that are genuinely
periodic by nature (§2's future daily quarantine-eligibility check,
§6's `PerformanceSnapshot` rollups) — never for reacting to a price move.

Mirrors `TradingLive.StrategyStockMonitor` structurally, renamed for the
options identity and paper-only execution:

```
TradingOptionsSim.ContractMonitor
  - GenServer, one per {strategy_version_run_id, contract_key} — NOT one
    per strategy, matching StrategyStockMonitor's "isolate blast radius"
    rationale (moduledoc decision #5): one contract's tick storm or a
    slow pricing lookup never delays another contract's evaluation, and a
    crash only restarts that one monitor.
  - Registered via `{:via, Registry, {TradingOptionsSim.MonitorRegistry, {run_id, contract_key_string}}}`
  - Supervised under `TradingOptionsSim.MonitorSupervisor`
    (DynamicSupervisor, :transient restart — same as trading_live's)
```

**Where trading_options_sim's monitor differs from trading_live's:**

| | `trading_live` `StrategyStockMonitor` | `trading_options_sim` `ContractMonitor` |
|---|---|---|
| Identity | `{live_strategy_id, symbol}` | `{run_id, contract_key}` (underlying+expiry+strike+right) |
| Price feed | subscribes `"prices:" <> symbol` on `TradingHub.PubSub` directly (real IBKR ticks) | subscribes to `"prices:" <> symbol` (the underlying's `symbol`) on this app's own **local** `TradingOptionsSim.PubSub` (relayed from `trading_hub` by `PriceRelay`/`IbPortfolio.HubClient` — see §4c, not a direct cross-node subscription per monitor), plus a **local options-pricing process** (§5a) for the derived option quote — no live options tick feed is assumed present |
| Order execution | `IBKR.Client.place_order/1` — real order, real fill broadcast | simulated fill: on a rule transition, computes a fill price from the current option pricing model (§5a) plus configurable slippage/spread assumptions, records a `SimFill` synchronously — no pending-order/timeout/stuck-order machinery needed since there's no real broker round-trip to wait on |
| Greeks | n/a | reads current delta/gamma/theta/vega from §5a's pricer, exposed in the rule-evaluation snapshot the same way `regime_trend_ordinal` is injected in `trading_live` (a computed pseudo-signal, not a subscribed catalog signal) |
| Expiry | n/a | must additionally watch for **contract expiry/DTE crossing zero** — a new lifecycle event stock monitors don't have (see §5b) |

### 5a. Options pricing — the piece with no existing analog

**Update 2026-09-13, re-verified directly against `trading_hub`'s
current code (not secondhand reports)** — the picture is better than
earlier notes assumed on one front, and precisely gapped on another:

- `tws_api` (PR #25, `0b71feb`): `req_contract_details/2` +
  `ContractDetails`/`ContractDetailsEnd` decode,
  `req_sec_def_opt_params/5` + `SecurityDefinitionOptionParameter`/`End`
  decode, `place_order/2` generalized for `"OPT"`, `TickOptionComputation`
  decode for greeks. **Not yet verified against live captured frames** —
  only against a reference bundle; `tws_api`'s own code flags this, and
  this week alone `OpenOrder`/`ExecDetails` each had real field-shift
  bugs only a live capture caught, twice each.
- `trading_hub` `TradingHub.IBKR.ContractResolver` (PR #101): resolves
  `(symbol, expiry, strike, right) -> con_id`, caches it. Confirmed
  still exists, unchanged shape (`contract_resolver.ex:72-77`).
- **New finding, corrects the earlier "not yet" note**:
  `trading_hub`'s market-data *subscription* wire support for options
  has actually landed — `TradingHub.IBKR.Subscriptions.send_req_mkt_data/3`
  now reads `:expiry`/`:strike`/`:right`/`:multiplier` off the contract
  map and places them in the `reqMktData` frame end-to-end, from
  `MarketData.Manager.subscribe_symbol/3` all the way down
  (`subscriptions.ex:284-334`). The caller must pass the option's
  OCC-style `local_symbol` as `symbol` (not the bare ticker) — that
  module's own doc comment explains why (`Subscriptions`' internal
  `symbol_to_req` map is keyed by bare string and would otherwise
  collide with the underlying stock's own subscription).
- **The real, still-open gap, confirmed by direct code read**: nothing
  turns a `TickOptionComputation` reply into a broadcast.
  `TradingHub.IBKR.MessageHandler` has **no clause at all** for
  `%Messages.TickOptionComputation{}` (`grep` across `trading_hub/lib`
  and `trading_hub/test`: zero hits) — greeks (delta/gamma/theta/vega/
  IV) are never decoded into anything a consumer app could subscribe to.
  Separately, `TradingHub.Message` has no option-aware shape at all:
  no `:greeks`/options message type in its type union, and
  `to_topic/1`'s only `:price` clause (`message.ex:160-162`) keys purely
  on a bare `symbol` string — no `con_id`/expiry/strike/right fields
  exist on the struct, so even a plain option price tick (via the
  now-working `TickPrice`/`TickSize` subscription) would carry identity
  only by informal convention (whatever OCC-style string a caller chose
  to subscribe with), never a structured field. `ContractResolver` is
  also not wired to the subscription path anywhere — nothing calls
  `resolve/4` and then turns the resulting `con_id` into a `subscribe/2`
  call; a consumer would have to glue those two independently-built
  pieces together itself.
**Update 2026-09-13, gap closed**: `trading_hub` shipped PR #102
(`e3e909e`/`995c2c3`), adding a `TickOptionComputation` handler clause.
Verified directly against the real code before building against it:
`MessageHandler` broadcasts a plain `%TradingHub.Message{type: :price,
symbol: <caller's OCC-style subscribe string>, data: %{implied_vol:,
delta:, opt_price:, pv_dividend:, gamma:, vega:, theta:, und_price:}}`
on `"prices:<symbol>"` — it reuses the existing `:price` type/topic
shape rather than adding a distinct `:greeks` type or structured
con_id/expiry/strike/right fields, so identity is still symbol-string-
only, exactly as flagged above. **`trading_hub`'s own commit message
states this is unverified against live TWS** — whether greeks actually
stream for a plain `"OPT"` subscription, or need an explicit generic-tick
code `Subscriptions.send_req_mkt_data/3` doesn't currently send, is an
open question on that app's side, not something `trading_options_sim`
can resolve from here.

Both pricing backends are now implemented:

- **v1 (default): Black-Scholes-derived paper pricing.**
  `TradingOptionsSim.Pricing.BlackScholes` + `ContractMonitor`'s
  `:black_scholes` mode (the default) — computes theoretical
  price/greeks from the underlying's real tick, a configurable
  implied-vol input, and time-to-expiry. Entirely local, no dependency
  on `trading_hub`'s option work being frame-verified.
- **v2 (opt-in, not the default): real IBKR quotes.**
  `TradingOptionsSim.Pricing.IBKRLive` + `ContractMonitor`'s
  `:pricing_backend: :ibkr_live` option — a small `GenServer` per
  contract's OCC symbol, subscribing to `"prices:<occ_symbol>"` and
  caching the latest greeks tick; `ContractMonitor` reads
  `IBKRLive.latest/1` on every underlying tick rather than polling.
  **Fails closed, never falls back to `BlackScholes`**: if no real tick
  has arrived yet (`{:error, :no_data}`), that evaluation is simply
  skipped — mixing a real quote with a synthetic one for the same
  contract would be worse than waiting. Requires `:occ_symbol` at
  start (raises `ArgumentError` without it) — this app does not derive
  an OCC symbol itself; that's `trading_hub`/`tws_api`'s own convention,
  supplied by whatever resolves the contract before starting the
  monitor (not yet built — see §9's remaining gap).

  Given `trading_hub`'s own frame-verification caveat, `:ibkr_live` is
  built and tested (with synthetic broadcasts, matching the confirmed
  wire shape) but is **not** the default — flip it per-monitor once
  someone confirms live greeks actually arrive against a real
  connection, not before.

  **Naming consistency paid off as intended**: `contract_key`'s
  `symbol`/`expiry` (raw `"YYYYMMDD"` string) fields, decided in §1
  specifically so this boundary would need no translation layer, meant
  `IBKRLive` needed zero field-renaming — only the already-planned
  `strike` `Decimal`↔`float` conversion at the `BlackScholes.compute/1`
  call site, unrelated to this new module.

### 5b. Expiry handling

A new lifecycle event with no stock equivalent: `ContractMonitor` tracks
DTE (days to expiry) and forces a close (`exit_reason: "expiry"`) at a
configurable cutoff (e.g. 1 DTE, to approximate avoiding
assignment/exercise mechanics this simulator doesn't model). LEAPS
versions simply have a much longer runway before this fires — no special
casing needed beyond "the expiry is far away," confirmed consistent with
`../OPTIONS_LEAPS_PLAN.md`'s framing that LEAPS aren't a separate concept.

## 6. Runs, fills, supervision tree

```
TradingOptionsSim.Sim.SimRun     — one open/close cycle for one contract
  (mirrors trading_system's StrategyRun / trading_live's LiveOrder+LiveFill
  combined, since there's no real order lifecycle to track separately —
  a run opens with a simulated fill and closes with another)
TradingOptionsSim.Sim.SimFill    — one simulated entry or exit fill
TradingOptionsSim.Sim.PerformanceSnapshot  — same rollup shape as
  trading_system's StrategyPerformanceSnapshot, computed off closed
  SimRuns, feeding the same quarantine-eligibility questions
  (n_trades, realized_pnl) once auto-quarantine is added (§2)
```

Supervision tree addition to `TradingOptionsSim.Application`:

```elixir
children = [
  ...,
  {Phoenix.PubSub, name: TradingOptionsSim.PubSub},
  {Registry, keys: :unique, name: TradingOptionsSim.MonitorRegistry},
  {DynamicSupervisor, name: TradingOptionsSim.MonitorSupervisor, strategy: :one_for_one},
  TradingOptionsSim.SimActivator,   # GenServer/Task mirroring StrategyActivator —
                                     # starts one ContractMonitor per {run, contract}
                                     # for every active version's resolved pool members
  ...
]
```

`SimActivator` mirrors `TradingLive.StrategyActivator`'s
`start_for_member/2` shape (§ code excerpt reviewed from that module):
for each active `StrategyVersion`, resolve its target pool's members,
compute each member's `contract_key` from the version's
`option_leg_config`, and `DynamicSupervisor.start_child/2` a
`ContractMonitor` keyed by `{run_id, contract_key}` if not already running
— same idempotent `whereis/2`-before-start guard trading_live uses to
avoid double-starting on a redundant activation call.

## 7. Explicitly out of scope for v1

- **Multi-leg structures** (verticals, iron condors, spreads) — schema
  leaves room (`option_leg_config.multi_leg`) but execution logic is
  single-leg only. Matches `../OPTIONS_LEAPS_PLAN.md`'s own explicit
  scope cut for combo orders on the `tws_api`/`trading_hub` side — no
  reason for the sim to get ahead of what the real trading path can
  eventually execute.
- **Real IBKR order placement** — this app is a simulator by name and by
  request; no `place_order` call ever reaches TWS. If a promoted version
  eventually needs to go live for real, that's a `trading_hub`/new-app
  question for later, out of this plan.
- **Automatic quarantine-eligibility worker** — start manual-only (§2),
  add the daily worker once there's real closed-run history.
- **A real IBKR options tick feed** — v1 prices synthetically (§5a).
- **Assignment/exercise mechanics** — expiry just force-closes the
  simulated position (§5b); no attempt to model being assigned early on a
  short leg (moot anyway at single-leg-long v1, matters once short legs
  or multi-leg exist).

## 8. Suggested build sequencing

1. **Schema + lifecycle** (§2, §3, §3a): `Strategy`/`StrategyVersion`/
   `TargetPool`/`TargetPoolMember`/`Tag`, porting `trading_system`'s
   lifecycle-transition and tagging logic and tests nearly verbatim. No
   external dependency — buildable and testable in isolation first.
2. **`ib_portfolio` + `PriceRelay`** (§4c): add the sibling `path:`
   dependency, start `IbPortfolio.HubClient` under this app's
   supervision tree, write `PriceRelay` (subscribes via `HubClient`,
   re-broadcasts onto local `TradingOptionsSim.PubSub`). No schema
   dependency — buildable and manually verifiable (confirm a real
   underlying tick arrives locally) independently of steps 1/3/4.
3. **Options pricing v1** (§5a): Black-Scholes pricer as a standalone
   module, unit-testable against known option-pricing examples before any
   GenServer wraps it.
4. **`ContractMonitor` + `MonitorSupervisor`/`Registry`** (§5, §6): the
   per-contract simulation loop, using stubbed/manual pool members before
   promotion (step 6) exists — lets the monitor pattern get proven against
   hand-authored native versions first, consuming step 2's `PriceRelay`
   feed and step 3's pricer. Needs `trading_core`'s
   `PositionSizing`/`RiskControls`/`ExitStrategy` to be options/multiplier-
   aware before real dollar sizing/risk math is correct here — see
   `TRADING_CORE_OPTIONS_UPDATE_PROMPT.md` (this directory), the handoff
   prompt for that `trading_core`-side work. A stub multiplier of 1 can
   unblock this step's own monitor-pattern development in the meantime,
   but must not be mistaken for correct options sizing.
5. **`SimActivator`** (§6): wires lifecycle-active versions to running
   monitors, mirroring `StrategyActivator`.
6. **API + MCP access, Settings page** (§4a, §4b): `ApiToken` schema,
   `/api/v1` routes and auth plug, `TradingOptionsSim.MCP.Server` +
   `CallGuard` (with `TableOwner` from day one — no reason to reintroduce
   the bug §4a documents), and the `/settings` LiveView with token
   management. Buildable once §1-3a's schema exists, independent of §4's
   actual cross-app client — this is what the client (and any operator
   or agent) will call against.
7. **Rename `promote_to_live_app` → `link_live_strategy`/`unlink_live_strategy`**
   (§4, corrected 2026-09-13): small, self-contained rename inside this
   app — no cross-app work needed on this app's own side. The actual
   pull-based promotion orchestration (`TradingLive.Client`,
   `promote_options_version/1`) is `trading_live`'s own future work, per
   §4's handoff prompt — not built here, not this app's session's job.
8. **Real IBKR option pricing swap-in** (§5a v2) — **done**, on
   `step8-impl` branch: `TradingOptionsSim.Pricing.IBKRLive` +
   `ContractMonitor`'s `:pricing_backend: :ibkr_live` option, consuming
   `trading_hub` PR #102's `TickOptionComputation` broadcast (which
   landed after this plan's earlier drafts, closing the gap those
   drafts described). Not the default — `trading_hub`'s own commit
   message flags live greeks streaming as unverified against real TWS,
   so `:black_scholes` stays the default until someone confirms it
   works end-to-end. `con_id` still stays an enrichment, never this
   app's own key (§1's divergence note) — `IBKRLive` doesn't use it
   either, since `trading_hub`'s broadcast doesn't carry one.

## 9. Current status (2026-09-13) and remaining gaps

Steps 1-8 of §8's sequencing are **built and merged to `main`**
(schema/lifecycle, `ib_portfolio`/`PriceRelay`, Black-Scholes pricer,
`ContractMonitor`/`SimActivator`, `/api/v1`, MCP server + Settings
LiveView, `link_live_strategy` rename, `IBKRLive` pricing backend).
Verified end-to-end against a real running dev server, including a
genuine live connection to a running `trading_hub` node (which
surfaced and fixed a real cross-node `Phoenix.PubSub` bug — see
`TradingHub.PubSub`'s own comment in `application.ex`).

**`trading_signal` integration is also now built** (branch
`add-trading-signal-integration`): `TradingOptionsSim.SignalConnection`
(distributed-Erlang connection to `trading_signal`, ported from
`TradingLive.SignalConnection` — connect/backoff, `:net_kernel.monitor_nodes/1`,
`request_signal/1` with slug->id caching, `safe_erpc/4`'s 3-shape
failure normalization) and `TradingOptionsSim.SignalBus` (the
config-swappable adapter seam, `Live`/`Test` implementations, ported
from `TradingLive.SignalBus` minus the `regime_sessions_between/2`
callback, which is `trading_live`-specific historical-regime-backfill
logic with no analog here). `ContractMonitor` now resolves
`TradingCore.RuleEngine.signal_names/1` against its `entry`/`exit`
rules on init, subscribes to each resolved `trading_signal` topic, and
merges received `{:signal, name, value}` values into the snapshot used
for the next price-driven rule evaluation (never evaluated
immediately on its own — same "wait for the next tick" posture
`:ibkr_live` already uses). 117 tests passing.

`TRADING_HUB_OPTION_TICKS_UPDATE_PROMPT.md`'s ask has been fulfilled —
`trading_hub` PR #102 added the `TickOptionComputation` broadcast that
prompt requested. That file is now historical; no further action needed
on it. See §5a's own update note for the precise wire shape this app now
consumes, and the real caveat (`trading_hub`'s own commit message: live
greeks streaming is unverified against real TWS) that keeps
`:ibkr_live` opt-in rather than the default.

Known remaining gaps, all real and none blocking current v1/v2 work:

- `Layouts`/`root.html.heex` are still the plain `mix phx.new` generator
  output — this app's own `DESIGN.md` "Dark Pool" theme (hardcoded dark
  DaisyUI theme, `Oswald`/`JetBrains Mono`, custom navbar) was never
  actually implemented. `SettingsLive` ships functional but unstyled
  against it. Separate design pass, not started.
- No `dev.exs` port assignment or entry in `trading_hub`'s
  `:cluster_app_ports` registry the way `trading_live` (4007) and
  `trading_system` (4004 UI / 4005 API) have — this app picked its own
  unused dev port (4008) unilaterally, but Erlang distribution needs
  `trading_hub`'s own side configured too for `IbPortfolio.HubClient` to
  reach it reliably outside this developer's own machine. Confirmed
  live 2026-09-13 that it *does* connect on this machine already (both
  nodes were already running under compatible names), so this gap may
  be narrower in practice than it looks — worth confirming before
  treating it as blocking.
- No `oban` dependency — needed once the automatic quarantine-eligibility
  worker (§2, deferred to a later phase) is built; not needed for v1.
- **New, from building `:ibkr_live`**: nothing in this app resolves an
  option contract to its OCC-style subscribe symbol yet —
  `ContractMonitor`'s `:occ_symbol` option must be supplied by the
  caller (`SimActivator` today never passes it; `:pricing_backend`
  defaults to `:black_scholes`, so this isn't exercised in practice
  yet). Building that resolution step (calling `tws_api`/`trading_hub`'s
  `ContractResolver`-adjacent machinery, or constructing the OCC string
  directly from `contract_key`) is real work still ahead of actually
  flipping any monitor to `:ibkr_live` for a specific contract.
- Whether `:ibkr_live` actually receives any ticks at all against a real
  TWS connection remains unverified — this app's own code is tested
  against the confirmed wire shape (synthetic broadcasts matching
  `trading_hub`'s real struct), but nobody has exercised it against a
  live option subscription yet. Do not flip a monitor to `:ibkr_live` in
  anything but a deliberate experiment until that's confirmed.

## Open questions

**Resolved 2026-09-13** (kept for history): "what does live mean for a
promoted options strategy" — answered by this session: `trading_live`
is the intended destination, via the same pull-based mechanism it
already uses against `trading_system` (§4). `trading_system` itself is
not involved in this app's design at all — an earlier draft of this
plan wrongly assumed it was.

Still open:

- Confirm quarantine/lifecycle settings (days required, min trades, min
  PnL) should start as direct copies of `trading_system`'s current
  defaults (20 trading days, 10 trades, $0 PnL — `LIFECYCLE.md` Settings
  table) or something else, given options' different trade cadence/sizing.
  Not yet operator-configurable in this app at all — still hardcoded
  where referenced (§2's schema defaults).
- Is promotion-in from `trading_system` (the originally-drafted, now
  abandoned §4 design — pulling proven equity signal logic into this
  app, supplying `option_leg_config` locally) worth building later as a
  *second*, additional on-ramp alongside native authoring and the
  trading_live pull-out? Nothing today requires it, and the schema
  fields for it (`source`, `source_trading_system_version_id`,
  `promoted_snapshot`) already exist unused if the answer is later yes —
  no urgency either way.
- §7's `promote_to_live_app` → `link_live_strategy` rename: worth doing
  now (cheap, no dependency) or waiting until `trading_live`'s own
  pull-side implementation actually exists and its session can confirm
  the exact field/endpoint shape it wants to call?
