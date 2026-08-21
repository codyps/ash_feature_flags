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
numeric TTL chain when the stream is `:down` (watcher registry consulted at
write time; on a `:down` transition the dispatcher clears that source's
entries so nothing is pinned stale across an outage). `invalidate/1`,
`error_ttl` and the failures-not-cached rule are unchanged.

This is the payoff piece: stream healthy → zero re-reads, instant changes;
stream broken → today's behaviour, automatically.

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

1. **Core plumbing** — `Changes` dispatcher (+ telemetry, PubSub, `on_change`
   hook), watcher supervision under `watch:`, health registry,
   `ttl :until_change`, `default_ttl/1` callback (LaunchDarkly → 0), Static
   routed through the dispatcher. Docs: new "Reacting to changes" README
   section replacing the bare `invalidate/1` advice.
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
