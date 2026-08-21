# Plan: streaming flag changes instead of TTL re-reads

## Problem

Every provider today is pull-only. Evaluations go through the ETS TTL cache
(`AshFeatureFlags.Cache`), so a flag flipped in the backend is invisible until
the TTL expires — and the only alternatives are a short TTL everywhere (load,
latency) or hand-wiring `AshFeatureFlags.invalidate/1` to a webhook yourself.

We want the library to *subscribe* to flag changes where the backend can tell
us about them, and react by invalidating (or updating) the cache — so entries
can live long, or forever, and still be correct within moments of a change.

## A constraint that shapes the whole design

Evaluation is **contextual**: Flipt, OFREP and LaunchDarkly all compute the
value per actor/targeting key, and our cache is keyed per flag *and* per
context hash. A change stream therefore cannot push new *values* — it can only
tell us the *rules* for a flag (or a whole namespace) changed. The universal
primitive is **targeted invalidation**: "flag X changed → drop every cached
entry for X, everyone re-evaluates lazily". `Cache.clear/1` already implements
exactly that (it match-deletes boolean and variant entries across all context
hashes), so the streaming layer is a set of *change sources* feeding one
dispatcher, not a new cache.

## What each backend actually supports

| Backend | Push mechanism | Verdict |
| --- | --- | --- |
| **LaunchDarkly** (Erlang SDK) | SDK already streams rule changes via SSE (`ldclient_update_stream_server`) into a local ETS store; evaluation is a local lookup. But the Erlang SDK exposes **no flag-change listener API** (its `ldclient_event*` modules are analytics export, not subscriptions — no equivalent of Go/Java's `FlagTracker`). | Streaming already exists *below* us. Our TTL cache in front of it is what adds staleness. Fix: stop caching, not add plumbing. |
| **flagd** (behind our OFREP provider) | True push: gRPC `flagd.sync.v1.FlagSyncService/SyncFlags` server-stream, plus `configuration_change` events on the evaluation `EventStream`. Also serves OFREP. | Supports streaming — but needs a gRPC client dep. Also fully covered by the OFREP ETag poller below at near-zero cost. |
| **OFREP** (generic: GO Feature Flag, Unleash Edge, Flipt's OFREP endpoint, …) | The protocol has **no push channel**. Its change-detection story is the bulk evaluation endpoint (`POST /ofrep/v1/evaluate/flags`) with `ETag` / `If-None-Match` → `304 Not Modified`; on a `200`, the spec says to emit `PROVIDER_CONFIGURATION_CHANGED` with the changed flag keys. | No streaming; **cheap change polling** is the sanctioned mechanism. |
| **OpenFeature in-process `client:` mode** | The Elixir OpenFeature SDK implements eventing, including `PROVIDER_CONFIGURATION_CHANGED` when the underlying provider emits it. | Supports it — adapter is a thin event handler. |
| **Flipt v1** (self-hosted, the server our provider targets) | No evaluation streaming. Two signals exist: **audit webhooks** (v1.27+, `flag:created/updated/deleted` events, HMAC-signed, filterable as `flag:*`) and its OFREP endpoint (ETag poller applies). | Webhook → invalidate is the native fit. |
| **Flipt v2 / Flipt Cloud** | Streaming mode: client SDKs hold a persistent connection and receive flag-state snapshots in real time (the `flipt-client-*` SDKs' `streaming` fetch mode). No Elixir client SDK exists. | Supports streaming; would need our own SSE consumer. Defer until v2 demand shows up. |
| **AshResource** (Postgres/SQLite table) | We *are* the write path when writes go through Ash — an `Ash.Notifier` on the FlagStore resource is a perfect in-process change stream, any data layer. Cross-node: Phoenix.PubSub. Out-of-band SQL writes: Postgres `LISTEN/NOTIFY` via a trigger + `Postgrex.Notifications`. SQLite has no cross-process notification — polling only. | Fully streamable on Postgres; in-process + PubSub everywhere; SQLite falls back to a cheap poll. |
| **Static** | `put/2` and `reset/0` already call `Cache.clear` synchronously. | Done today (single node). Route through the new dispatcher so tests/telemetry see the same events. |

## Architecture

Three small pieces, all additive:

### 1. `AshFeatureFlags.Changes` — the dispatcher

One module every change source funnels into:

```elixir
AshFeatureFlags.Changes.notify(:flipt, {:changed, ["new-checkout"]})
AshFeatureFlags.Changes.notify(:flipt, {:changed, :all})   # snapshot changed, keys unknown
AshFeatureFlags.Changes.notify(:flipt, :up | :down)        # stream health
```

On `{:changed, keys}` it:

* calls `Cache.clear/1` per key (or `clear/0` for `:all`)
* emits telemetry `[:ash_feature_flags, :change]` with `%{source:, keys:}`
* broadcasts on Phoenix.PubSub when configured
  (`config :ash_feature_flags, pubsub: MyApp.PubSub` — optional dep, resolved
  at runtime like ash_authentication is), topic `"ash_feature_flags:changes"`.
  This both fans invalidations out across nodes **and** gives LiveViews a
  re-render signal for free.
* invokes a user hook if configured (`config :ash_feature_flags, on_change: {M, :f}`)

PubSub subscription is symmetric: the dispatcher subscribes too, so a webhook
landing on one node invalidates every node. Broadcast messages carry a node
tag to avoid re-broadcast loops. Two consistency-driven constraints (see the
consistency section): PubSub delivery is best-effort, so it is only
load-bearing for webhook sources, which are staleness-bounded anyway —
polling/streaming watchers run per node. And the dispatcher is a single
GenServer so that each source's `{:changed, ...}`/`:down`/`:up` events are
applied in order, with invalidation stamps written before the corresponding
deletes (the fence protocol).

### 2. Watchers — one process per change source

A new optional provider callback:

```elixir
@callback change_stream(keyword()) :: Supervisor.child_spec() | nil
```

started by `AshFeatureFlags.Application` for providers listed under a new
`config :ash_feature_flags, watch: [provider_refs]` (mirroring the existing
`providers:`/`child_spec/1` mechanism, but explicit — watching is opt-in
because it opens sockets/timers). Each watcher reports `:up`/`:down`/
`{:changed, keys}` to `Changes`.

### 3. Cache semantics: `ttl :until_change`

A new TTL value at every level (flag `ttl`, resource `cache_ttl`, app
`cache_ttl`): entries are written without expiry **while the flag's provider
has a healthy change stream**, and the evaluator falls back to the normal
numeric TTL chain when the stream is `:down`. Health is tracked per *source
id* (see the restructuring section) — the watcher registry is consulted at
cache-write time, and on a `:down` transition the dispatcher calls
`Cache.clear_source/1` for exactly that source, so nothing is pinned stale
across an outage and no other backend's entries are touched. `error_ttl` and
the failures-not-cached rule are unchanged; `invalidate/1` keeps its public
contract but routes through the dispatcher.

This is the payoff piece: stream healthy → zero re-reads, instant changes;
stream broken → today's behaviour, automatically.

## Does the existing code need restructuring?

Reviewed with watchers in mind. The dispatcher/watcher layer is genuinely
additive — no rewrite of the evaluator or cache is needed — but five things in
the current code either block the design or would be fought against later.
The first is a real prerequisite; the rest are small and best done in the same
pass (Phase 0 below).

### 1. There is no "source identity" — the enabling refactor

Cache keys are `{phash2(provider_ref), flag_key, context_hash}` where
`provider_ref` is the **fully merged** `{module, opts}` computed per
evaluation by `Evaluator.provider_for/3` (flag → opts → resource → app
config). Watchers, by contrast, are configured statically. Nothing connects
"the watcher for Flipt namespace `billing` went down" to "these cache entries
came from Flipt namespace `billing`":

* `:until_change` health gating needs *per-source* clearing on a `:down`
  transition; today the only correct reaction would be `Cache.clear/0` —
  every source pays for one source's outage.
* The evaluator needs to ask "is the stream for *this flag's* provider
  healthy?" at cache-write time, and there is no stable term to key that
  lookup on: the merged ref differs per flag/resource even when it is the
  same backend.
* Incidentally, hashing the *entire* opts into the key means non-semantic
  options (`receive_timeout`, `retry`) fragment the cache today.

Fix: a new optional provider callback

```elixir
@callback source_id(keyword()) :: term()
```

returning a compact identity term — the options that select *which backend
answers*, nothing else. Flipt: `{Flipt, base_url, namespace, reference}`;
OpenFeature: `{OpenFeature, base_url, path_prefix}` (or `{:client, client}`);
LaunchDarkly: `{LaunchDarkly, instance}`; AshResource: `{AshResource,
resource, tenant}`; default when not exported: `{module, opts}` in full, which
preserves today's behaviour exactly. The cache key becomes
`{source_id, flag_key, context_hash}` (stored literally — small and
debuggable), giving:

* `Cache.clear/1` unchanged — its match pattern `{{:_, key, :_}, ...}`
  doesn't care what the first element is.
* A new `Cache.clear_source(source_id)` via the same `match_delete`.
* Health registry and watcher registration keyed by `source_id`; the
  evaluator resolves flag → provider ref → `source_id` → health, all terms it
  already has in hand.

This must land before any watcher does, or `:until_change` degrades to
"clear the world on any hiccup".

### 2. TTL resolution is provider-blind

`Evaluator.ttl_for/3` is a pure config lookup returning an integer, resolved
independently of `provider_for/3`. `:until_change` makes TTL a function of
the provider's stream health, so `ttl_for` must take the resolved
`{provider, opts}` (available at both call sites already) and return
`:infinity | non_neg_integer()`. Local refactor, plus widened specs on
`Cache.fetch/3` / `Cache.put/3`.

The cache *storage and sweep* need no change: Erlang term ordering puts every
atom above every integer, so an `expires_at` of `:infinity` survives both the
read check (`expires_at > now()`) and the sweeper's `{:<, :"$1", now()}` guard
— verified empirically against the real module. But `Cache.put/3` computes
`now() + ttl` and **raises `ArithmeticError` on `:infinity`** (also verified),
so `put/3` and `fetch/3` need an explicit `:infinity` clause. Phase 0 pins
both with unit tests.

### 3. `child_spec/1` is the wrong hook for watchers — latent collision

`Application.provider_children/0` starts anything under `providers:` that
exports `child_spec/1`. But `use GenServer` *auto-generates* `child_spec/1`,
so the first provider implemented as a GenServer would be silently started as
its own "poller" by that mechanism. No current provider trips this, but the
watcher work multiplies GenServers. Keep `child_spec/1` for what it is (SDK
clients), add the distinct `change_stream/1` callback for watchers under the
separate `watch:` key, and implement watchers as their own modules
(`Provider.OpenFeature.Poller`), never on the provider module itself.

### 4. Invalidation call sites bypass any future dispatcher

`Static.put/reset`, `AshResource.put/3` and the public
`AshFeatureFlags.invalidate/1` all call `Cache.clear` directly. Once
`Changes` exists they must route through it, or provider-initiated writes
won't broadcast across nodes and won't show up in change telemetry.
Semantics: `Cache.clear` stays the node-local primitive; `Changes.notify`
= clear + telemetry + PubSub; `invalidate/1` re-points at `Changes` (that is
what someone hand-wiring a webhook wants).

### 5. `Cache.init/1` owns unrelated state

The cache GenServer owns the cache table, the sweep timer, *and* Static's
override table. With a dispatcher, a health registry and a watcher supervisor
arriving, restructure the application tree explicitly:

```
AshFeatureFlags.Supervisor
├── AshFeatureFlags.Cache            # cache table + sweep only
├── AshFeatureFlags.Changes          # dispatcher + health registry (+ Static's table)
├── provider children (providers:)   # unchanged
└── AshFeatureFlags.WatcherSupervisor (watch:)
```

Watchers under their own supervisor so a crash-looping poller can hit its
restart limit without taking the cache down; `Changes` starts before watchers
so there is always somewhere to report to.

### Also required, easily missed: HTTP response headers

The `AshFeatureFlags.HTTP` behaviour's response type is
`%{status:, body:}` — no headers, so the OFREP poller cannot read `ETag`.
Extend the contract to `%{status:, body:, headers:}` with readers using
`Map.get(resp, :headers, [])`, so existing custom `http_client:` stubs keep
working unmodified. `HTTP.Req` and the test `FakeHTTP` grow header support
(and a 304 fixture) in Phase 0/3.

## Consistency: every way a change can be missed, and the invariant that stops it

Invalidation-on-change trades the TTL's *bounded* staleness for *zero*
staleness — but only if no change is ever missed. A missed change under
`ttl :until_change` is **unbounded** staleness, which is strictly worse than
today. So each hole below gets a closing mechanism, and they roll up into one
invariant:

> **A cache entry may outlive its TTL only while an actively health-checked
> change stream vouches for it — and any doubt (disconnect, reconnect, gap,
> unverifiable delivery) is resolved by dropping entries, never by keeping
> them.**

### Hole 1: the in-flight stale write (verified against the real code)

`Cache.fetch/3` computes-then-puts. Sequence, reproduced with the actual
module: entry cleared → request misses → provider HTTP call starts (reads
*old* rules) → backend flips the flag → watcher fires `Cache.clear(key)` →
the in-flight call returns and **writes the pre-change value after the
invalidation ran**. Today a wrong value is pinned for one TTL; under
`:until_change` it is pinned forever. This race needs no pathological timing —
any change landing inside a provider round-trip triggers it, and changes are
most likely exactly when people are toggling flags.

Fix: an **invalidation-stamp fence** in `Cache`, Phase 0. A second ETS table
records `last_invalidated_at` per flag key, per source, and globally, written
with monotonic time *before* the corresponding `match_delete`. `fetch` notes
`started_at` before invoking the provider fun; the subsequent put becomes
"insert, then re-read the stamps, and self-delete if any stamp moved past
`started_at`". Both interleavings converge: if the insert lands before the
invalidator's delete, the delete removes it; if after, the stamp (written
first) is already visible and the put self-deletes. No locks, no serialization
of the hot read path. The fence applies to numeric TTLs too — it fixes a real
(if smaller) bug that exists today.

Validated with a prototype under an adversarial randomized schedule (provider
read racing a mid-flight change + clear, 2000 runs): today's put-after-compute
pinned the stale value in **670/2000** runs; the fence pinned it in **0/2000**.
The stamp table stays tiny — one row per flag key ever invalidated, and a
stamp only matters while a provider call that started before it is still in
flight, so the existing sweep can prune stamps older than the longest
conceivable provider round-trip (a minute is generous; the default
`receive_timeout` is 2s).

### Hole 2: events missed while a stream is down — including the reconnect gap

A watcher that disconnects and reconnects has a window where events fired and
nobody listened. Treating `:up` as "resume trusting the cache" silently keeps
entries that predate the gap. Rule: **both `:down` and `:up` transitions write
the source's invalidation stamp and clear the source** — state after a gap is
unknown until re-observed. The stamp fence from Hole 1 covers the in-flight
variant automatically (an evaluation started before the reconnect can't
populate an `:until_change` entry after it). Watchers that can cheaply resync
on connect (the OFREP poller's first fetch, flagd's initial `SyncFlags`
payload) get freshness back immediately; the clear just guarantees nothing
stale survives the gap.

### Hole 3: sources with no liveness signal (webhooks)

A webhook that never arrives is indistinguishable from no change: the app was
deploying, the LB dropped it, the HMAC secret rotated, Flipt's sink queue
overflowed. There is no `:down` to observe. Consequence, stated as a hard
rule: **webhook-fed sources never qualify for unbounded `:until_change`** —
they resolve it to the configurable `max_staleness` bound (default ~10 min).
Better: pair the webhook with the OFREP reconciliation poller against the same
backend — the webhook becomes a *latency optimization* (sub-second reaction)
while the poller is the *correctness mechanism* (bounded, health-checked).
Belt and suspenders, and each is simple alone.

### Hole 4: the ETag poller's blind spot

Diffing bulk-evaluation results under one sentinel context **cannot see every
rule change**: a targeting change scoped to `role=admin` leaves a non-admin
sentinel's values untouched. Two consequences:

* Never use the per-flag diff as the *detector*. On any ETag change, clear
  the whole source; the diff is only a log/telemetry nicety. Invalidation is
  lazy re-evaluation, so over-clearing costs one provider round-trip per
  actively-used flag+actor, not a stampede of wasted work.
* Whether the ETag itself is computed over the *configuration* (catches
  everything) or over the *evaluated results* (same blind spot as the diff)
  is server-dependent and mostly undocumented. So by default, poller-fed
  `:until_change` is **also bounded by `max_staleness`**, liftable per source
  (`trust_etag: true`) when the operator knows their server hashes config —
  flagd and GO Feature Flag can be verified and documented case by case.

### Hole 5: cross-node divergence

If one node's watcher detects a change and other nodes depend on a PubSub
broadcast to hear about it, a netsplit or dropped message leaves those nodes
pinned stale with no signal. Rule: **polling/streaming watchers run on every
node** — each node's cache is guarded by its own watcher, and cross-node
delivery is never load-bearing for them. The per-node cost is small (a 304
poll or one SSE socket per node). PubSub fan-out remains for the one source
class that inherently lands on a single node — webhooks — and those already
carry `max_staleness` (Hole 3), so a lost broadcast heals within the bound.
A singleton-watcher-plus-broadcast architecture is explicitly rejected: it
turns another node's health into this node's correctness.

### Hole 6: AshResource writes that never reach the notifier

Ash notifications fire after commit, but two paths skip them: raw SQL /
out-of-band writes, and the documented Ash caveat where writes inside a
caller-managed transaction return notifications for the *caller* to send
(the "missed notifications" warning). So the Ash-notifier stream is
best-effort. Postgres gets a truthful stream instead: the trigger +
`LISTEN/NOTIFY` listener fires on commit regardless of write path, and
`Postgrex.Notifications` monitors its connection — giving real
`:down`/`:up` transitions that plug into Hole 2's rule. Qualification table:
trigger+listener → full `:until_change`; notifier-only (SQLite, ETS, or
Postgres without the trigger) → `max_staleness` bound.

### Non-consistency note: invalidation stampedes (measured)

`Cache.fetch/3` has no single-flight: 50 concurrent readers of one cleared
key produced 50 provider calls (measured). TTL expiry has the same behavior
today, but a change event synchronizes the miss across *all* actors of a flag
at once. Keys are per-actor, so per-key single-flight wouldn't dedupe anyway.
Accept it for v1 (the burst is bounded by requests actually in flight),
document it, and note `stale_while_revalidate` as a possible later mode —
it deliberately reintroduces one round-trip of staleness, so it must stay
opt-in.

### What does *not* need restructuring

* The evaluator pipeline (role short-circuits → cache → provider → on_error)
  is untouched; watchers never sit in the request path.
* The `Provider` behaviour stays backward compatible — `source_id/1` and
  `change_stream/1` are optional with behaviour-preserving defaults.
* `Cache.clear/1`'s key-matching design already anticipated this feature; it
  keeps working across the key-shape change.

## Per-backend work

**LaunchDarkly** — no watcher at all. Add an optional provider callback
`default_ttl/1`; the LD provider returns `0` (evaluation is a local ETS read —
our cache saves nothing and only adds staleness on top of the SDK's own SSE
stream). Evaluator consults it after flag/resource/app config so an explicit
TTL still wins. Document why `:until_change` doesn't apply (no listener API in
the Erlang SDK; if LaunchDarkly ever ships one, a watcher slots in).

**AshResource** —
* `AshFeatureFlags.FlagStore` auto-registers an `Ash.Notifier` on the flag
  resource: any create/update/destroy → `Changes.notify(:ash_resource,
  {:changed, [record.key]})`. Works on every data layer, covers AshAdmin and
  any app code, no configuration. Best-effort though (Hole 6): raw SQL and
  Ash's caller-managed-transaction caveat both skip it, so notifier-only
  setups keep the `max_staleness` bound; only trigger + LISTEN/NOTIFY below
  unlocks full `:until_change`.
* Multi-node comes free via the PubSub fan-out above.
* Out-of-band SQL writes (Postgres): an optional
  `AshFeatureFlags.Provider.AshResource.Listener` watcher using
  `Postgrex.Notifications`, plus a documented migration snippet
  (`AFTER INSERT OR UPDATE OR DELETE` trigger doing
  `pg_notify('ash_feature_flags', key)`). Opt-in via `watch:`.
* SQLite: document as poll-only; the generic poller below can diff
  `max(updated_at)` if someone needs it.

**Flipt (v1)** — `AshFeatureFlags.Webhook.Flipt`, a Plug the user mounts:

```elixir
forward "/webhooks/flipt", AshFeatureFlags.Webhook.Flipt, secret: {:system, "FLIPT_WEBHOOK_SECRET"}
```

Verifies the HMAC signature, accepts `flag:*` audit events, maps
namespace/flag key → `Changes.notify`. Webhooks carry no liveness signal
(Hole 3), so `:until_change` for webhook-fed providers resolves to the
configurable `max_staleness` bound (default ~10 minutes), never `:infinity`.
The recommended setup pairs the webhook with the OFREP reconciliation poller
against the same Flipt: webhook = sub-second latency, poller = bounded
correctness.

**OpenFeature / OFREP** — `AshFeatureFlags.Provider.OpenFeature.Poller`
watcher: `POST {base_url}/ofrep/v1/evaluate/flags` with `If-None-Match` on a
configurable interval (default 15s), evaluated under a fixed sentinel
context. `304` → nothing (and proves the source healthy). `200` (ETag moved)
→ **clear the whole source** — per-flag diffing is telemetry only, never the
detector, because a rule change scoped away from the sentinel context leaves
the sentinel's values unchanged (Hole 4). Whether the server's ETag hashes
the *config* or the *evaluated results* is server-dependent, so poller-fed
`:until_change` stays bounded by `max_staleness` unless the source is marked
`trust_etag: true`. Reuses `AshFeatureFlags.HTTP`/`FakeHTTP`, no new deps.
This covers flagd, GO Feature Flag, Unleash Edge and Flipt in one stroke.

**OpenFeature in-process client** — when `client:` is set, attach an
OpenFeature event handler for `PROVIDER_CONFIGURATION_CHANGED` and forward
`flagsChanged` to `Changes`. Tiny adapter, SDK resolved at runtime.

**flagd gRPC sync stream / Flipt v2 SSE** — real push, deferred: the gRPC dep
(`grpcbox`/`grpc`) is heavy for a library whose HTTP story is optional `req`,
and the OFREP poller already gets flagd to ~interval-latency for free. If
demand appears, each is an isolated watcher module (Flipt v2's SSE can ride
`Req` response streaming, no new dep). Explicitly out of scope for the first
release.

**Static** — route `put/reset` through `Changes` instead of calling
`Cache.clear` directly, so tests exercise the same pipeline and multi-node
dev setups behave.

## Phases

0. **Prerequisite restructuring** (see "Does the existing code need
   restructuring?") — `source_id/1` callback + cache key shape
   `{source_id, flag_key, context_hash}` + `Cache.clear_source/1`; the
   invalidation-stamp fence in `Cache.fetch`/`clear` (Hole 1 — fixes a real
   race that exists under numeric TTLs today); provider-aware `ttl_for` with
   `:infinity` support in `put/3`/`fetch/3` (+ term-ordering and
   `ArithmeticError` regression tests); application tree split
   (Cache / Changes / WatcherSupervisor); HTTP response headers. Behaviour
   change is limited to the fence closing the existing race; ships alone.
1. **Core plumbing** — `Changes` dispatcher (+ telemetry, PubSub, `on_change`
   hook), watcher supervision under `watch:`, health registry keyed by
   source id, `ttl :until_change`, `default_ttl/1` callback (LaunchDarkly →
   0), Static and `AshResource.put/3` and `invalidate/1` routed through the
   dispatcher. Docs: new "Reacting to changes" README section replacing the
   bare `invalidate/1` advice.
2. **AshResource** — FlagStore `Ash.Notifier`; PubSub fan-out test with two
   sandboxed dispatcher instances; Postgres LISTEN/NOTIFY watcher + migration
   docs.
3. **OFREP poller** — ETag/diff watcher against `FakeHTTP`; wire the example
   app's flagd demo to it.
4. **Flipt webhook plug** — HMAC verification, event filtering, example app
   endpoint + stub demo.
5. **(on demand)** flagd gRPC sync watcher, Flipt v2 SSE watcher, OpenFeature
   client event adapter.

## Testing notes

* Watchers are plain GenServers taking a `notify:` fun — unit-testable without
  the dispatcher.
* `FakeHTTP` grows ETag/304 support for the poller; webhook plug tested with
  `Plug.Test` and real HMACs.
* `:until_change` needs an evaluator test matrix: stream up (no expiry),
  stream down (fallback TTL), down-transition (entries dropped), *and*
  up-transition after a gap (entries dropped — Hole 2).
* Race regression tests from the probe that motivated the fence: an
  invalidation landing during a slow provider fun must not leave the stale
  result cached; `put/fetch` with `:infinity` must not raise; sweep must
  retain `:infinity` entries. (Probe script: five scenarios run against the
  real `Cache` module confirmed the race, the `ArithmeticError`, sweep
  behavior, source-id key matching, and the 50-caller stampede.)
* Example app: `mix demo` gains a "flip a flag mid-run, watch the table
  change without a TTL wait" scenario per backend.

## Non-goals

* Pushing evaluated *values* to callers (contextual evaluation makes
  invalidation the correct primitive; see above).
* A gRPC dependency in the core package.
* Changing default behaviour: with no `watch:` config and numeric TTLs,
  nothing observable changes.
