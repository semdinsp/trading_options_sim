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
  underlying: "AAPL",
  expiry: ~D[2027-01-15],   # LEAPS is just a far-dated expiry, no separate concept
  strike: Decimal.new("150.00"),
  right: "C" | "P"
}
```

Serialized as a stable string (`"AAPL:2027-01-15:150.00:C"`) wherever a
single string key is needed (Registry name, PubSub topic suffix, map key).
A resolved IBKR `con_id` is stored alongside once available but is **not**
part of the identity — mirrors `tws_api`'s contract-resolution plan
(`../OPTIONS_LEAPS_PLAN.md` step 1): con_id is an enrichment, not the key,
so the sim can carry a contract before/without ever resolving it against
TWS (this app doesn't need a live IBKR connection to run — see §5).

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
    "promoted_from_trading_system" — see §4)
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
  - underlying_symbol, underlying_exchange, underlying_currency
  - underlying_ib_conid (nil until resolved — see §5)
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

## 4. Promotion: pulling a version id from trading_system

Mirrors `trading_live/lib/trading_live/trading_system/client.ex` closely:

```
TradingOptionsSim.TradingSystem.Client
  - get_version(version_id)       # GET /api/v1/versions/:id
  - get_strategy(strategy_id)     # GET /api/v1/strategies/:id
  - get_target_pool(target_pool_id)  # GET /api/v1/target_pools/:id
  - list_instruments(asset_class) # GET /api/v1/instruments
  - mark_promoted(version_id)     # POST .../promote {"to": "live"} — bookkeeping only
  - link_to_live_strategy(version_id, options_sim_strategy_id)  # NEW verb needed on trading_system, see below
  - unlink_from_live_strategy(version_id)
```

Same auth model (bearer token + base URL, operator-configured on this
app's own `/settings` page — see §4b — rather than hardcoded, once that
page exists; `config :trading_options_sim, :trading_system_api_token`
remains the escape-hatch/test default), same fire-and-forget posture for
the marker POSTs (a promotion here must never roll back because a
bookkeeping call to `trading_system` failed), same `Req`-based client
with a `req_plug` test seam.

**Promotion flow** (`TradingOptionsSim.Sim.promote_from_trading_system/2`,
mirrors `trading_live`'s `LiveTrading.promote_version/1`):

1. Fetch the `trading_system` `StrategyVersion` + parent `Strategy` +
   `TargetPool` (if any) via the Client.
2. Validate it's option-eligible — since `trading_system` is currently
   equity/pairs-oriented (per its `LIFECYCLE.md`/`STRATEGY_SKILL.md`), a
   promoted version's `rules`/`usage_conditions` describe **entry/exit
   signal logic**, not option-specific leg selection. Promotion carries
   the signal logic over into a frozen `promoted_snapshot`, and the
   operator supplies `option_leg_config` (§2) at promotion time — it has
   no equivalent on the trading_system side to copy from. This is the one
   real gap in "just pull a version id over": `trading_system` doesn't
   know what a call/put/strike/expiry is. Confirmed acceptable scope
   split: signal logic (when to be long/short) comes from `trading_system`;
   options-structuring logic (which contract, how the leg is chosen)
   is `trading_options_sim`-native and supplied at promotion.
3. Create a local `StrategyVersion` row: `source: "promoted_from_trading_system"`,
   `source_trading_system_version_id`, `lifecycle_stage: "discovery"`
   (a promoted version still starts at `discovery` in *this* app's own
   lifecycle — promotion crosses apps, it doesn't skip this app's own
   evaluation window), `promoted_snapshot` = frozen copy of the source's
   `rules`/`usage_conditions`/`params`.
4. Call `Client.link_to_live_strategy/2` (fire-and-forget) so
   `trading_system`'s own dashboard shows this version as linked/active
   elsewhere — same transparency `link_strategy_version_to_trading_live/2`
   already provides for `trading_live`.
5. Never re-synced afterward — identical "frozen at promotion" contract as
   `trading_live`'s `LiveStrategy` (see that schema's moduledoc,
   `final_imp.md` decision #2). Iterating means re-forking on the
   `trading_system` side and re-promoting, not editing the local copy.

**Cross-app change needed on `trading_system`'s side** (hand off, do not
edit directly): its `link_trading_live`/`unlink_trading_live` endpoints and
`trading_live_active`/`trading_live_strategy_id` fields are named for one
specific consumer app. Two options, to be decided with the user before
handoff:
   - (a) Generalize the field/endpoint names to something consumer-agnostic
     (`linked_consumer_app`, `linked_consumer_strategy_id`) — bigger
     change, cleaner long-term if a third consumer app ever shows up.
   - (b) Add a parallel `trading_options_sim_active`/
     `trading_options_sim_strategy_id` pair, `link_trading_options_sim`/
     `unlink_trading_options_sim` endpoints — smaller, consistent with how
     `trading_live`'s own fields were added incrementally, but doesn't
     generalize.
   Recommendation: (b) for now, matching the codebase's own incremental
   pattern (`trading_live_active` etc. were themselves added as a single
   named link, not a generic one, per `LIFECYCLE.md`'s "Linking to a
   `trading_live` LiveStrategy" section) — revisit if a third consumer
   appears.

**Native (non-promoted) versions**: nothing above is mandatory — an
operator can author a `StrategyVersion` directly in
`trading_options_sim` (`source: "native"`) and run it through the same
discovery/quarantine/target-pool lifecycle without ever touching
`trading_system`. Promotion is an *optional* on-ramp for reusing signal
logic already proven elsewhere, not a required path.

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

**REST API — `/api/v1`**, mirroring `trading_system`'s `STRATEGYCLAUDE.md`
surface, scoped to what this app actually needs exposed for cross-app
promotion (§4) and promote-out (§2):

```
GET    /api/v1/strategies                    strategies:read
GET    /api/v1/strategies/:id                strategies:read
POST   /api/v1/strategies                     strategies:write
POST   /api/v1/strategies/:id/versions        strategies:write
GET    /api/v1/versions/:id                   strategies:read
POST   /api/v1/versions/:id/promote           strategies:write   (discovery->quarantine, quarantine->test_portfolio, retired->discovery)
POST   /api/v1/versions/:id/downgrade         strategies:write   (->retired, or test_portfolio->quarantine)
POST   /api/v1/versions/:id/promote_from_trading_system   strategies:write   (§4's inbound flow)
POST   /api/v1/versions/:id/promote_to_live_app           strategies:write   (§2's outbound marker)
GET    /api/v1/target_pools, /:id             target_pools:read
POST   /api/v1/target_pools, .../members      target_pools:write
GET    /api/v1/tags                           tags:read
POST   /api/v1/versions/:id/tags              tags:write
```

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

Initial tool set, each a thin wrapper around a `Sim` context function
(mirrors `trading_system.MCP.Server`'s "thin wrapper around
already-existing, already-tested context functions" posture) — read
tools need no scope beyond a valid token, write tools require
`scopes: ["mcp:write"]` on the component:

```
list_strategies            get_strategy             list_strategy_versions
get_version_performance    list_target_pools        get_target_pool
list_tags
---
create_strategy            create_strategy_version
promote_version            downgrade_version
promote_from_trading_system   promote_to_live_app
add_strategy_version_tag   set_strategy_version_tags
```

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
  as `"prices:" <> underlying_symbol`, which is what `ContractMonitor`
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

## 5. Per-contract monitor (the "monitors" pattern)

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
| Price feed | subscribes `"prices:" <> symbol` on `TradingHub.PubSub` directly (real IBKR ticks) | subscribes to `"prices:" <> underlying_symbol` on this app's own **local** `TradingOptionsSim.PubSub` (relayed from `trading_hub` by `PriceRelay`/`IbPortfolio.HubClient` — see §4c, not a direct cross-node subscription per monitor), plus a **local options-pricing process** (§5a) for the derived option quote — no live options tick feed is assumed present |
| Order execution | `IBKR.Client.place_order/1` — real order, real fill broadcast | simulated fill: on a rule transition, computes a fill price from the current option pricing model (§5a) plus configurable slippage/spread assumptions, records a `SimFill` synchronously — no pending-order/timeout/stuck-order machinery needed since there's no real broker round-trip to wait on |
| Greeks | n/a | reads current delta/gamma/theta/vega from §5a's pricer, exposed in the rule-evaluation snapshot the same way `regime_trend_ordinal` is injected in `trading_live` (a computed pseudo-signal, not a subscribed catalog signal) |
| Expiry | n/a | must additionally watch for **contract expiry/DTE crossing zero** — a new lifecycle event stock monitors don't have (see §5b) |

### 5a. Options pricing — the piece with no existing analog

Nothing in this workspace currently prices an option today (confirmed:
`../OPTIONS_LEAPS_PLAN.md` step 2 is still open — `TickOptionComputation`
decode doesn't exist in `tws_api` yet). Two paths, pick based on how soon
real IBKR option ticks are needed:

- **v1 (recommended to start): Black-Scholes-derived paper pricing.**
  `ContractMonitor` computes its own theoretical price/greeks from the
  underlying's real tick (flowing in via `PriceRelay`/`ib_portfolio`,
  §4c), a configurable implied-vol input (flat, or a simple vol-surface
  stub), and time-to-expiry — entirely local, no dependency on `tws_api`'s
  unfinished option market-data work. Good enough to validate strategy
  logic (entry/exit rules, position sizing, lifecycle) well before real
  option quotes are available.
- **v2 (once `tws_api`/`trading_hub`'s options work lands): real IBKR
  option quotes.** Swap the pricer for a subscription to
  `trading_hub`'s option market data (once that exists per
  `../OPTIONS_LEAPS_PLAN.md`) — `ContractMonitor`'s rule-evaluation
  interface (a snapshot map with price/greeks keys) stays the same either
  way, so this is meant to be a swappable pricing backend
  (`TradingOptionsSim.Pricing.BlackScholes` vs.
  `TradingOptionsSim.Pricing.IBKRLive`), not a rewrite.

This ordering also sidesteps a real dependency risk: this app should not
be blocked on `tws_api`'s option decode work landing first.

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
7. **`TradingSystem.Client` + promotion flow** (§4): needs the
   `link_trading_options_sim`/`unlink_trading_options_sim` endpoints added
   to `trading_system` first — hand off that prompt once steps 1-5 have
   validated the local shape enough to know exactly what promotion needs
   to populate. Also needs step 6's Settings page to exist (where the
   operator configures the outbound token/base URL).
8. **Real IBKR option pricing swap-in** (§5a v2) — once `tws_api`'s
   `ContractDetails`/`TickOptionComputation` work lands. See
   `TWS_API_OPTIONS_UPDATE_PROMPT.md` (this directory) — the handoff
   prompt for that `tws_api`-side work, per this workspace's cross-app
   boundary rule.

## 9. Current skeleton gaps (as of this writing)

Confirmed by reading the app directly: `trading_options_sim` is a fresh,
unmodified `mix phx.new` generator output. Concretely missing, all
addressed by the sequencing above:

- No `Registry`/`DynamicSupervisor` in `Application.start/2` yet (§6).
- `{:app_status, git: ...}` and its `/status`/`/status/metrics`
  wiring, `TradingOptionsSim.StatusExtension` — **done** (added this
  session; see git history). `hub_connected?/0` currently reports `false`
  unconditionally pending §4c's `ib_portfolio`/`HubClient` integration —
  update it once that lands, per §4c's own note.
- `{:ib_portfolio, path: "../ib_portfolio"}` (§4c) — not yet added.
  Needed before `PriceRelay`/`ContractMonitor` (§5) can receive real
  underlying ticks from `trading_hub`.
- No `dev.exs` port assignment or entry in `trading_hub`'s
  `:cluster_app_ports` registry the way `trading_live` (4007) and
  `trading_system` (4004 UI / 4005 API) already have — needed before this
  app's `IbPortfolio.HubClient` can actually reach `trading_hub`'s node
  (Erlang distribution needs both sides configured, not just this app's
  own `hub_node` setting). Since this touches `trading_hub`'s own config,
  adding the registry entry is a small hand-off prompt for that app's
  session, not a direct edit here; picking this app's own unused dev port
  is a local, unilateral choice.
- `req` is already a dependency (used for the `trading_system` promotion
  client, §4) — no new HTTP-client dependency needed.
- No `oban` dependency — needed once the automatic quarantine-eligibility
  worker (§2, deferred to a later phase) is built; not needed for v1.

## Open questions for the user before implementation starts

- Confirm scope split in §4 step 2: signal logic from `trading_system`,
  option-structuring config supplied locally at promotion — or should
  `trading_system` itself grow option-aware `usage_conditions` so a
  promoted version arrives fully configured?
- Confirm §4's cross-app link naming choice (a vs. b) before that handoff
  prompt is drafted.
- Confirm quarantine/lifecycle settings (days required, min trades, min
  PnL) should start as direct copies of `trading_system`'s current
  defaults (20 trading days, 10 trades, $0 PnL — `LIFECYCLE.md` Settings
  table) or something else, given options' different trade cadence/sizing.
- What does "live" actually mean for a promoted options strategy? Does an
  options-capable execution app already exist or is planned (a
  `trading_live`-equivalent that knows how to place real option orders,
  which itself depends on `../OPTIONS_LEAPS_PLAN.md`'s still-open
  `tws_api` order-placement work, step 3), or is `promote_to_live_app/2`
  (above) meant to sit unimplemented/stubbed until that consumer exists?
  This plan assumes the latter — `test_portfolio` is as far as this app's
  own lifecycle goes, and the handoff point is deliberately left
  consumer-agnostic — but worth confirming before building the promotion
  marker fields.
