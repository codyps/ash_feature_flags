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
tag to avoid re-broadcast loops.

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

Happily the cache storage format needs **no** change: Erlang term ordering
puts every atom above every integer, so an `expires_at` of `:infinity`
survives both the read check (`expires_at > now()`) and the sweeper's
`{:<, :"$1", now()}` guard untouched. Phase 0 should pin that with a unit
test rather than rely on it silently.

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
  any app code, no configuration.
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
namespace/flag key → `Changes.notify`. Also document Flipt's OFREP endpoint as
an alternative via the poller below. Webhooks don't carry stream health, so
`:until_change` pairs with a long safety-net TTL rather than `:infinity` —
resolve `:until_change` for webhook-fed providers to a configurable
`max_staleness` (default e.g. 10 minutes).

**OpenFeature / OFREP** — `AshFeatureFlags.Provider.OpenFeature.Poller`
watcher: `POST {base_url}/ofrep/v1/evaluate/flags` with `If-None-Match` on a
configurable interval (default 15s). `304` → nothing (and proves the stream
healthy). `200` → diff against the previous body per flag key, notify exactly
the changed keys. Evaluated against a fixed sentinel context — any rule change
shows up as *some* diff, and the reaction is key-level invalidation, so
per-actor accuracy of the sentinel values is irrelevant. Reuses
`AshFeatureFlags.HTTP`/`FakeHTTP`, no new deps. This covers flagd, GO Feature
Flag, Unleash Edge and Flipt in one stroke.

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
   `{source_id, flag_key, context_hash}` + `Cache.clear_source/1`;
   provider-aware `ttl_for` with `:infinity` support (+ term-ordering unit
   test); application tree split (Cache / Changes / WatcherSupervisor);
   HTTP response headers. Pure refactor, no behaviour change, ships alone.
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
  stream down (fallback TTL), down-transition (entries dropped).
* Example app: `mix demo` gains a "flip a flag mid-run, watch the table
  change without a TTL wait" scenario per backend.

## Non-goals

* Pushing evaluated *values* to callers (contextual evaluation makes
  invalidation the correct primitive; see above).
* A gRPC dependency in the core package.
* Changing default behaviour: with no `watch:` config and numeric TTLs,
  nothing observable changes.
