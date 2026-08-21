# AshFeatureFlags example app

One Ash resource, one set of policies, four flag backends. There are two ways
to see it work: a terminal run that asserts the whole matrix, and a LiveView
page you can click through.

```
mix setup
mix demo --stub     # the matrix, in the terminal
mix server          # the playground, on http://localhost:4000
```

```
── Flipt (http://127.0.0.1:18080) ────────

  actions — the guard vetoes, it never grants
  ✓ customer may express_checkout their own order        flag on + ownership rule passes
  ✓ support may NOT express_checkout                     flag is on, but the resource's own policy refuses — a flag cannot grant
  ✓ customer may NOT add_gift_wrap                       policy would allow it; the guard vetoes because the flag is off
  ✓ admin may add_gift_wrap                              enabled_for_roles [:admin] turns the flag on for them
  ✓ Ash.can? agrees, so a UI can hide the button         guards are policies, so can?/3 reflects them
  ✓ the refusal carries the declared message             message: "Gift wrapping is not available yet."

  attributes — visibility follows the flag
  ✓ predicted_ltv is hidden from a customer              ml-scoring is off, so the field policy denies it
  ✓ predicted_ltv is hidden from an admin too            field guards are about the flag, not the role
  ✓ filtering on predicted_ltv is refused                prevent_filtering? closes the bisection leak a field policy leaves open
  ✓ fraud_notes is visible to support                    fraud-tooling is targeted at them in the backend
  ✓ fraud_notes is hidden from a customer                same flag, different evaluation context
  ...

  84 checks · 84 passed · 0 failed
```

## Running it

| command | what it does | needs |
| --- | --- | --- |
| `mix demo --offline` | Static + SQLite only | nothing |
| `mix demo --stub` | all four, Flipt/flagd stubbed on loopback | nothing |
| `mix demo` | all four, against Docker | `docker compose up -d` |
| `mix demo -p flipt` | just one provider | that provider |
| `mix server` | the LiveView playground on :4000 | nothing (Docker for flipt/flagd) |

`--stub` runs `ExampleApp.StubServer`, a small Plug router that speaks Flipt's
and OFREP's wire protocols. It is a **stand-in, not the real services** — it
exists so you can watch the HTTP providers make real requests and parse real
responses on a machine with nothing installed. For the real thing:

```bash
docker compose up -d
mix demo
```

## The playground

```bash
mix server   # http://localhost:4000
```

The same order the demo uses, rendered live. Pick who you are, pick which
backend answers, and watch fields and buttons appear and disappear:

* **Support** sees `fraud_notes`, because every backend targets that flag at the
  `roles` property — and loses the Express checkout button, because the
  resource's own policy refuses. A flag guard vetoes an action; it never grants
  one.
* **Admin** gets the gift wrap button while `gift-wrapping` is still off in
  every backend, via `enabled_for_roles [:admin]`.
* Flipping `ml-scoring` makes `predicted_ltv` appear with no redeploy — on the
  Static and SQLite backends, which can be written at runtime. Flipt and flagd
  read `docker/` at boot, so the playground disables their toggles rather than
  pretending.
* Changing the backend changes nothing on the page. That is the point.

Nothing there is hidden with CSS. The page reads the order **as the actor**, so
a guarded field that is off arrives as `%Ash.ForbiddenField{}` — the value never
left the server — and buttons are drawn from `Ash.can?/2`.

It also shows the two ways to use a flag side by side: the guarded fields and
actions are declared in the resource's `feature_flags` block and this LiveView
never asks about them, while the loyalty discount is an ordinary
`AshFeatureFlags.enabled?/2` call in the view, because a discount is a view
concern. Forget the `:if` around the discount and you have shipped the feature;
forget it around a guarded field and the resource still refuses.

No asset pipeline — Phoenix and LiveView each ship a prebuilt browser bundle,
so there is no `npm install` and no build step. See
[`lib/example_app_web/playground_live.ex`](lib/example_app_web/playground_live.ex).

> The provider selector writes application config, so it changes the backend for
> the whole node, not just your browser tab. Fine for a demo, not a pattern to
> copy.

## What's in here

| file | why it's worth reading |
| --- | --- |
| [`lib/example_app/shop/order.ex`](lib/example_app/shop/order.ex) | the flagged resource — read the `feature_flags` and `policies` blocks side by side |
| [`lib/example_app/providers.ex`](lib/example_app/providers.ex) | the same flag state expressed four different ways |
| [`lib/example_app/demo.ex`](lib/example_app/demo.ex) | every scenario, with the reason it should hold |
| [`lib/example_app_web/playground_live.ex`](lib/example_app_web/playground_live.ex) | the same thing you can click — declared guards vs. a flag checked in the view |
| [`docker/flipt/features.yml`](docker/flipt/features.yml) | Flipt segments and rollouts |
| [`docker/flagd/flags.json`](docker/flagd/flags.json) | flagd JsonLogic targeting |
| [`lib/example_app/flags/feature_flag.ex`](lib/example_app/flags/feature_flag.ex) | the database flag table — five lines, because `FlagStore` brings the rest |

## The scenario

Three actors and one order:

| actor | role |
| --- | --- |
| ada@example.com | customer, owns the order |
| sam@example.com | support |
| root@example.com | admin |

Five flags, seeded identically into every backend:

| flag | state | expressed as |
| --- | --- | --- |
| `express-checkout` | on | a plain boolean everywhere |
| `gift-wrapping` | off | a plain boolean; admins bypass it via `enabled_for_roles` |
| `ml-scoring` | off | a plain boolean |
| `fraud-tooling` | on for `role=support` | Flipt segment / flagd JsonLogic / `allowed_roles` column / a function |
| `loyalty-pricing` | 50% rollout | Flipt threshold / flagd `fractional` / `rollout_percentage` column |

The resource declares the guards:

```elixir
feature_flags do
  flag :gift_wrapping do
    enabled_for_roles [:admin]     # staff dogfooding, regardless of the backend
  end

  guard_action [:express_checkout], flag: :express_checkout
  guard_action [:add_gift_wrap], flag: :gift_wrapping,
    message: "Gift wrapping is not available yet."

  guard_attribute [:predicted_ltv], flag: :ml_scoring
  guard_attribute [:fraud_notes], flag: :fraud_tooling, prevent_filtering?: false
end
```

...and, separately, who may do what:

```elixir
policies do
  policy action_type([:update, :destroy]) do
    authorize_if actor_attribute_equals(:role, :admin)
    authorize_if expr(customer_id == ^actor(:id))
  end
end
```

Neither block mentions the other. The three results worth understanding:

- **support may not `express_checkout`**, even though the flag is on. A guard
  vetoes; it can never grant. The ownership policy still has to pass.
- **customer may not `add_gift_wrap`**, even though the policy would allow it.
  The flag is off, so the guard refuses — with the declared message.
- **admin may `add_gift_wrap`** while it is off for everyone else, because
  `enabled_for_roles [:admin]` short-circuits the backend. They still need a
  policy to authorize the action, which admins have.

## Attribute visibility

`predicted_ltv` and `fraud_notes` are guarded, so while their flag is off they
come back as `%Ash.ForbiddenField{}` rather than their value.

The two are guarded differently on purpose:

- `predicted_ltv` uses the default, which **also refuses reads that filter on
  it**. Hiding a value is not enough by itself — `filter(predicted_ltv > 100)`
  would still narrow the result set and leak the number a bisection at a time.
- `fraud_notes` sets `prevent_filtering? false`: hidden from responses, but
  safe to filter on.

`fraud-tooling` is targeted at support **in the backend**, not in the resource,
which is what makes the field visible to sam@example.com and hidden from
ada@example.com with no Elixir code involved.

## SQLite or Postgres

The flag table is an ordinary Ash resource, so the data layer is your choice.
`lib/example_app/flags/feature_flag.ex` in full:

```elixir
use Ash.Resource,
  domain: ExampleApp.Flags,
  data_layer: AshSqlite.DataLayer,
  extensions: [AshFeatureFlags.FlagStore]

sqlite do
  table "feature_flags"
  repo ExampleApp.Repo
end
```

To run it against the `postgres` service in `docker-compose.yml` instead:

1. `{:ash_postgres, "~> 2.6"}` in `mix.exs` (in place of `ash_sqlite`)
2. `use AshPostgres.Repo` in `lib/example_app/repo.ex`, and point the config at
   `postgres://postgres:postgres@localhost/example_app_dev`
3. swap `data_layer:` and the `sqlite do` block for `postgres do` in the three
   resources

Nothing in `AshFeatureFlags` changes — `Provider.AshResource` only ever calls
`Ash.read_one/2`.

## The fifth provider: LaunchDarkly

LaunchDarkly is deliberately not wired into the demo, because unlike Flipt and
flagd it cannot be run from a container with a seed file — it needs an account
and an SDK key, so there would be nothing to `docker compose up`.

Adding it is three lines:

```elixir
# mix.exs
{:launchdarkly_server_sdk, "~> 3.0"}
```

```elixir
# lib/example_app/application.ex, before the supervisor starts
:ldclient.start_instance(System.fetch_env!("LAUNCHDARKLY_SDK_KEY"))
```

```elixir
# lib/example_app/providers.ex
def ref(:launchdarkly, _opts), do: AshFeatureFlags.Provider.LaunchDarkly
```

...then add `:launchdarkly` to `names/0` and give `seed/1` a clause that checks
reachability the way the Flipt and flagd clauses do. Create the same five flags
in the LaunchDarkly dashboard, with `fraud-tooling` targeted at contexts whose
`roles` attribute contains `support`, and the demo runs against it unchanged.

The actor becomes an LDContext of kind `user`, keyed on the same targeting key
every other provider sees — so a percentage rollout selects the same people.

## Talking to a real Flipt with auth

The compose file runs Flipt with authentication off so the demo needs no setup.
With a token, the provider takes one:

```elixir
{AshFeatureFlags.Provider.Flipt,
 base_url: "http://localhost:8080",
 token: {:system, "FLIPT_TOKEN"}}
```

## Environment

```bash
FLIPT_URL=http://flipt.internal:8080 mix demo -p flipt
FLAGD_URL=http://flagd.internal:8016 mix demo -p flagd
FLIPT_NAMESPACE=billing mix demo -p flipt
```
