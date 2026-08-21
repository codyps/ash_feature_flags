# AshFeatureFlags

Feature flags for [Ash](https://ash-hq.org) resources.

Declare flags on a resource, then gate **actions** and **attribute visibility**
behind them. Guards compile into `Ash.Policy.Authorizer` policies, which is what
makes them compose with `ash_authentication`'s roles and rules instead of
fighting them.

Flags can come from [Flipt](https://flipt.io), any
[OpenFeature](https://openfeature.dev) OFREP server (flagd, GO Feature Flag,
...), [LaunchDarkly](https://launchdarkly.com), or a plain database table in
Postgres or SQLite.

```elixir
defmodule MyApp.Shop.Order do
  use Ash.Resource,
    domain: MyApp.Shop,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshFeatureFlags]

  feature_flags do
    provider {AshFeatureFlags.Provider.Flipt, base_url: "http://flipt:8080"}

    flag :new_checkout do
      description "Rewritten checkout flow"
      enabled_for_roles [:admin]
    end

    flag :ml_pricing

    guard_action [:checkout], flag: :new_checkout
    guard_attribute [:predicted_ltv], flag: :ml_pricing
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(customer_id == ^actor(:id))
    end
  end
end
```

## See it running

[`example/`](example/) is a working app: one Ash resource, one set of policies,
and the same scenario matrix run against all four backends. If the tables
match, nothing in the application had to know which one it was talking to.

```bash
cd example
mix setup
mix demo --stub     # all four providers, no Docker needed
docker compose up -d && mix demo   # ...and against real Flipt and flagd
```

## Installation

```elixir
def deps do
  [
    {:ash_feature_flags, "~> 0.1"},
    # only if you use Flipt, OpenFeature or LaunchDarkly:
    {:req, "~> 0.5"}
  ]
end
```

```elixir
# config/config.exs
config :ash_feature_flags,
  provider: {AshFeatureFlags.Provider.Flipt, base_url: "http://flipt:8080"},
  cache_ttl: :timer.seconds(5),
  on_error: :default
```

## Guarding actions

```elixir
guard_action [:create, :update], flag: :new_checkout
guard_action :read, flag: :beta_reads, message: "Beta reads are not open yet"
guard_action :publish, flag: [:editor_v2, :publishing], match: :all
```

Each guard compiles to a policy that *vetoes* the action while the flag is off:

```elixir
policy action(:publish) do
  forbid_unless flag_enabled(:publishing_v2)
  authorize_if always()
end
```

The trailing `authorize_if always()` is what makes it a veto rather than a
grant. Ash requires every applicable policy to pass, so the guard ANDs with your
own rules — it can never open an action that your policies would have refused.

Because it is a real policy, `Ash.can?/3` reflects it, so a UI can hide the
button rather than let the user press it and be refused:

```elixir
Ash.can?({MyApp.Shop.Order, :checkout, %{}}, current_user)
```

`ash_graphql`, `ash_json_api` and AshAdmin get the same behaviour for free.

## Guarding attributes

```elixir
guard_attribute [:predicted_ltv, :ml_tier], flag: :ml_pricing
guard_attribute :internal_notes, flag: :support_tooling
```

This compiles to an Ash field policy. While the flag is off, the field comes
back as `%Ash.ForbiddenField{}` instead of its value, and is omitted from
GraphQL/JSON:API responses. Works for public attributes, calculations and
aggregates.

**Filtering is also blocked.** Hiding a value is not enough on its own —
`filter(predicted_ltv > 5000)` would still narrow the result set and leak the
value a bisection at a time. By default a read that filters on a hidden field is
refused outright. Opt out per guard with `prevent_filtering? false` when the
field is safe to filter on and you only mean to hide it from responses.

If the resource had no field policies of its own, a `field_policy :*` catch-all
is added alongside yours, because Ash requires every public field to be covered
once any field policy exists. Adding the extension never hides a column you
didn't name.

## Working with ash_authentication

`ash_authentication` handles *who you are*; its roles and rules live in your
policies. A flag guard is also a policy, so the two AND together with no glue:

```elixir
policies do
  # your existing rule: only editors may publish
  policy action(:publish) do
    authorize_if actor_attribute_equals(:role, :editor)
  end
end

feature_flags do
  flag :publishing_v2 do
    # you and the rest of the admins get it regardless of rollout
    enabled_for_roles [:admin]
  end

  guard_action [:publish], flag: :publishing_v2
end
```

| actor | flag off | flag on |
| --- | --- | --- |
| editor | ✗ refused | ✓ allowed |
| customer | ✗ refused | ✗ refused (role rule) |
| admin | ✓ allowed (`enabled_for_roles`) | ✓ allowed |

Two things are picked up from the actor automatically:

**Roles** — read from the attributes named by
`config :ash_feature_flags, role_keys: [:role, :roles]`. Both a single value
(`role: :admin`) and a list (`roles: ["admin", "billing"]`) work, and values are
normalized, so `enabled_for_roles [:admin]` matches a `"Admin"` string from the
database.

**Targeting key** — the `ash_authentication` subject (`"user?id=8e2b..."`), the
same identifier it puts in tokens and sessions. Percentage rollouts keyed on it
are stable per user across requests, nodes and restarts. Without
`ash_authentication` the primary key is used instead.

`ash_authentication` is never a dependency of this library; it is resolved at
runtime and simply used when present.

## Flags in policies you write yourself

Guards cover "the flag must be on *as well*". When you need a different shape —
an OR, a kill switch, a variant — use the checks directly:

```elixir
import AshFeatureFlags.Checks.Builtins

policies do
  # admins always; everyone else only while the flag is on
  policy action_type(:create) do
    authorize_if actor_attribute_equals(:role, :admin)
    authorize_if flag_enabled(:public_commenting)
  end

  # a kill switch reads better as a forbid
  policy action_type([:update, :destroy]) do
    forbid_if flag_enabled(:comments_frozen)
    authorize_if always()
  end

  # multivariate
  policy action(:read) do
    authorize_if flag_variant(:checkout_experiment, "treatment")
  end
end
```

These work on any resource, with or without the extension. Ash fixes the set of
modules imported into `policies`/`field_policies` blocks, hence the explicit
`import`; the tuple form `{AshFeatureFlags.Checks.FlagEnabled, flag: :x}` needs
no import at all.

## Outside of policies

```elixir
AshFeatureFlags.enabled?(:new_checkout, actor: current_user)

AshFeatureFlags.enabled?(:ml_pricing,
  actor: current_user,
  resource: MyApp.Shop.Order,
  context: %{country: "NZ"}
)

AshFeatureFlags.all_enabled?([:a, :b], actor: user, match: :any)
{:ok, variant} = AshFeatureFlags.variant(:checkout_experiment, actor: user)

AshFeatureFlags.with_flag(:new_checkout, [actor: user],
  fn -> new_checkout(order) end,
  fn -> legacy_checkout(order) end
)
```

Pass `resource:` whenever the flag is declared in a resource's `feature_flags`
block. That is what lets the call see the declaration — the `enabled_for_roles`
short-circuit, a per-flag provider, the declared `default`. Without it the flag
is looked up in `config :ash_feature_flags, :flags` and otherwise treated as
default-off, which is rarely what you meant.

## Providers

| Provider | Backend |
| --- | --- |
| `AshFeatureFlags.Provider.Flipt` | Flipt's evaluation API |
| `AshFeatureFlags.Provider.OpenFeature` | any OFREP server (flagd, GO Feature Flag, ...) |
| `AshFeatureFlags.Provider.LaunchDarkly` | LaunchDarkly, via the Erlang SDK |
| `AshFeatureFlags.Provider.AshResource` | a database table |
| `AshFeatureFlags.Provider.Static` | config and in-memory overrides, for tests |

Providers resolve flag → resource → application config, so you can set a global
default and override where it matters:

```elixir
feature_flags do
  provider {AshFeatureFlags.Provider.Flipt, namespace: "billing"}

  flag :ml_pricing do
    # migrate one flag at a time
    provider {AshFeatureFlags.Provider.LaunchDarkly, instance: :production}
  end
end
```

Everything the provider needs about the caller is in
`AshFeatureFlags.Context` — actor, targeting key, roles, tenant, resource and
action — so segment and targeting rules can be written against roles and tenants
directly in Flipt or LaunchDarkly.

### Flipt

```elixir
config :ash_feature_flags,
  provider: {AshFeatureFlags.Provider.Flipt,
             base_url: "http://flipt:8080",
             namespace: "default",
             token: {:system, "FLIPT_TOKEN"}}
```

### OpenFeature / flagd

```elixir
config :ash_feature_flags,
  provider: {AshFeatureFlags.Provider.OpenFeature, base_url: "http://flagd:8016"}
```

Or delegate to an in-process OpenFeature SDK client, in which case no HTTP call
is made:

```elixir
provider {AshFeatureFlags.Provider.OpenFeature, client: OpenFeature.get_client()}
```

### LaunchDarkly

```elixir
# mix.exs
{:launchdarkly_server_sdk, "~> 3.0"}

# application start
:ldclient.start_instance(System.fetch_env!("LAUNCHDARKLY_SDK_KEY"))

# config
config :ash_feature_flags, provider: AshFeatureFlags.Provider.LaunchDarkly
```

The actor becomes an LDContext of kind `user`, keyed on the
`ash_authentication` subject.

### A database table (Postgres, SQLite, ...)

`AshFeatureFlags.FlagStore` turns one of your own resources into the flag table,
so the data layer is your choice:

```elixir
defmodule MyApp.Flags.FeatureFlag do
  use Ash.Resource,
    domain: MyApp.Flags,
    data_layer: AshPostgres.DataLayer,   # or AshSqlite.DataLayer
    extensions: [AshFeatureFlags.FlagStore]

  postgres do
    table "feature_flags"
    repo MyApp.Repo
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end
end
```

```elixir
config :ash_feature_flags,
  provider: {AshFeatureFlags.Provider.AshResource, resource: MyApp.Flags.FeatureFlag}
```

You get `key`, `enabled`, `description`, `rollout_percentage`, `allowed_roles`,
`allowed_tenants`, `variant`, `metadata`, timestamps, CRUD actions and a
`by_key` read. Everything is added with `add_new_*`, so anything you declare
yourself wins.

A row is evaluated in this order:

1. `enabled` false → off. The master switch always wins.
2. `allowed_tenants` non-empty and the tenant is not in it → off
3. the actor holds one of `allowed_roles` → on, skipping the rollout
4. `rollout_percentage` set → on if the targeting key hashes below it. The hash
   is salted with the flag key, so two 20% flags do not hit the same 20% of
   users, and stable per actor, so nobody sees the feature flicker.
5. otherwise → on

### Static, for tests

```elixir
# config/test.exs
config :ash_feature_flags, provider: AshFeatureFlags.Provider.Static, cache_ttl: 0
```

```elixir
test "checkout is gated" do
  AshFeatureFlags.Provider.Static.put("new-checkout", false)

  assert {:error, %Ash.Error.Forbidden{}} =
           MyApp.Shop.checkout(order, actor: user)
end
```

Values may also be functions of the context, which is how you express targeting
without a real backend:

```elixir
AshFeatureFlags.Provider.Static.put("beta", fn context -> :admin in context.roles end)
```

Overrides are global, so tests that set them should not be `async: true`.

## Failure behaviour

Flag evaluation happens inside the request path. When the backend is down, the
`on_error` strategy decides what happens, and the failure is logged either way:

| `on_error` | behaviour |
| --- | --- |
| `:default` (default) | use each flag's declared `default` |
| `:disable` | treat the flag as off |
| `:enable` | treat the flag as on |
| `:raise` | let the error propagate |

Since `default` is `false` unless you say otherwise, an outage closes the gate
rather than opening it. Set it per flag when that is wrong:

```elixir
flag :new_checkout do
  # already fully rolled out; an outage should not take checkout with it
  default true
  on_error :default
end
```

## Caching

Results are cached in ETS per flag *and* per actor, so a percentage rollout
still varies between users. TTL resolves flag → resource → `config
:ash_feature_flags, cache_ttl: 5_000`. `0` disables caching, which is what you
want for a kill switch:

```elixir
flag :signups_paused do
  ttl 0
end
```

The key covers everything sent to the provider — roles, tenant, resource,
action, actor attributes, extra context, the flag's variant, and the provider's
own options. Two Flipt namespaces, or a flag rolled out for reads but not
writes, never share an entry.

Rather than running a very short TTL everywhere, drop entries when your backend
tells you something changed:

```elixir
AshFeatureFlags.invalidate("new-checkout")   # provider-side key
AshFeatureFlags.invalidate(:new_checkout)    # or the flag name
AshFeatureFlags.invalidate()                 # everything
```

Provider *failures* are not cached, so a one-second blip cannot pin a flag to
its fallback. The cost is that a real outage pays a fresh provider timeout on
every guarded action and field of every request. If that matters more, cache
the fallback briefly:

```elixir
config :ash_feature_flags, error_ttl: :timer.seconds(2)
```

Flags with `ttl 0` never cache their failures regardless.

## Telemetry

* `[:ash_feature_flags, :evaluate, :start | :stop | :exception]`

`:stop` metadata carries `flag`, `key`, `resource`, `provider`, `result` and
`source` — where `source` is `:cache`, `:provider`, `:role` (a
`enabled_for_roles` / `disabled_for_roles` short-circuit) or `:error`. Watching
the `:error` rate is the cheapest way to notice a flag backend degrading.

## Compile-time checks

Mistakes surface at `mix compile`, not at 3am:

* a guard referencing a flag that was never declared
* a guard on an action that does not exist
* `guard_attribute` on a missing, private, or primary-key field — with an
  explanation of why a primary key can never be hidden, and what to do instead

## Adding the extension to a resource that wasn't using policies

Guards are policies, so the extension registers `Ash.Policy.Authorizer` on your
resource. On a resource that did not have it, that would normally forbid
everything no policy authorizes. To keep "add the extension" from locking down
actions you never asked to guard, a catch-all `policy always()` is appended in
that case — so unguarded actions behave exactly as they did before.

A resource that **already declared the authorizer** never gets the catch-all,
even with no policies at all — that is Ash's deny-everything posture, and
adding this extension must not be able to open a resource that was closed.

Once you are ready to write full policies, opt out:

```elixir
feature_flags do
  unguarded_actions :deny
end
```

Resources that already have policies, or already declare the authorizer, are
never given a catch-all.

## License

MIT
