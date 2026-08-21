defmodule AshFeatureFlags.Dsl do
  @moduledoc false

  alias AshFeatureFlags.{ActionGuard, AttributeGuard, Flag}

  @provider_type {:or, [{:behaviour, AshFeatureFlags.Provider}, :mod_arg]}

  @flag %Spark.Dsl.Entity{
    name: :flag,
    describe: """
    Declares a feature flag this resource knows about.

    Declaring a flag is what makes it referenceable from `guard_action`,
    `guard_attribute` and `flag_enabled/1` checks, and is where you set the
    provider key, the fallback value, and any role short-circuits.
    """,
    examples: [
      """
      flag :new_checkout do
        description "Rewritten checkout flow"
        default false
      end
      """,
      """
      flag :ml_pricing do
        key "ml-pricing-v2"
        provider {AshFeatureFlags.Provider.LaunchDarkly, environment: :production}
        enabled_for_roles [:admin]
        ttl :timer.seconds(30)
      end
      """
    ],
    target: Flag,
    args: [:name],
    identifier: :name,
    transform: {Flag, :transform, []},
    no_depend_modules: [:provider],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name used to refer to this flag in guards and checks."
      ],
      key: [
        type: :string,
        doc:
          "The key as it exists in your flag backend. Defaults to the dasherized name (`:new_checkout` -> `\"new-checkout\"`)."
      ],
      description: [
        type: :string,
        doc: "Human readable description, surfaced in policy breakdowns."
      ],
      default: [
        type: :boolean,
        default: false,
        doc:
          "The value used when the provider cannot be reached and `on_error` is `:default`. Default to `false` so an outage closes the gate rather than opening it."
      ],
      provider: [
        type: @provider_type,
        doc:
          "Overrides the provider for this flag only. Useful while migrating one flag at a time between backends."
      ],
      variant: [
        type: :string,
        doc:
          "Treat this flag as on only when the provider returns this variant. Turns a multivariate flag into a boolean one."
      ],
      ttl: [
        type: :non_neg_integer,
        doc:
          "Cache TTL in milliseconds for this flag. `0` disables caching (use for kill switches)."
      ],
      on_error: [
        type: {:one_of, [:default, :enable, :disable, :raise]},
        doc: "What to do when the provider errors. Overrides the section-level setting."
      ],
      enabled_for_roles: [
        type: {:list, {:or, [:atom, :string]}},
        default: [],
        doc:
          "Actor roles for which this flag is always on, without consulting the provider. Lets you dogfood with `[:admin]` regardless of rollout."
      ],
      disabled_for_roles: [
        type: {:list, {:or, [:atom, :string]}},
        default: [],
        doc:
          "Actor roles for which this flag is always off. Checked before `enabled_for_roles`, so a deny always wins."
      ],
      context: [
        type: :map,
        default: %{},
        doc: "Static key/values merged into the evaluation context sent to the provider."
      ]
    ]
  }

  @guard_action %Spark.Dsl.Entity{
    name: :guard_action,
    describe: """
    Only allow these actions to run while the flag is on.

    This compiles to an `Ash.Policy.Authorizer` policy that *vetoes* the action
    when the flag is off. It never grants access on its own: your existing
    policies still have to authorize the request independently, so an
    `ash_authentication` role rule and a feature flag compose as AND.
    """,
    examples: [
      "guard_action [:create, :update], flag: :new_checkout",
      "guard_action :read, flag: :beta_reads, message: \"Beta reads are not open yet\"",
      "guard_action :publish, flag: [:editor_v2, :publishing], match: :all"
    ],
    target: ActionGuard,
    args: [:actions],
    transform: {ActionGuard, :transform, []},
    schema: [
      actions: [
        type: {:wrap_list, :atom},
        required: true,
        doc: "The action name(s) to guard."
      ],
      flag: [
        type: {:wrap_list, :atom},
        required: true,
        doc: "The flag name(s) that must be on."
      ],
      match: [
        type: {:one_of, [:all, :any]},
        default: :all,
        doc: "With several flags, whether all of them or any of them must be on."
      ],
      variant: [
        type: :string,
        doc: "Require the flag to have this variant rather than merely being on."
      ],
      message: [
        type: :string,
        doc: "Error message shown when the action is refused because the flag is off."
      ],
      description: [
        type: :string,
        doc: "Description used in policy breakdowns."
      ]
    ]
  }

  @guard_attribute %Spark.Dsl.Entity{
    name: :guard_attribute,
    describe: """
    Only expose these fields while the flag is on.

    Compiles to an Ash field policy. When the flag is off the field comes back
    as `%Ash.ForbiddenField{}` instead of its value, is `nil` in filters, and is
    omitted by `ash_graphql`/`ash_json_api`. Works for public attributes,
    calculations and aggregates.
    """,
    examples: [
      "guard_attribute [:experimental_score, :ml_tier], flag: :ml_pricing",
      "guard_attribute :internal_notes, flag: :support_tooling"
    ],
    target: AttributeGuard,
    args: [:attributes],
    transform: {AttributeGuard, :transform, []},
    schema: [
      attributes: [
        type: {:wrap_list, :atom},
        required: true,
        doc: "The field name(s) to hide while the flag is off."
      ],
      flag: [
        type: {:wrap_list, :atom},
        required: true,
        doc: "The flag name(s) that must be on for the fields to be visible."
      ],
      match: [
        type: {:one_of, [:all, :any]},
        default: :all,
        doc: "With several flags, whether all of them or any of them must be on."
      ],
      variant: [
        type: :string,
        doc: "Require the flag to have this variant rather than merely being on."
      ],
      prevent_filtering?: [
        type: :boolean,
        default: true,
        doc: """
        Also refuse reads that *filter* on the field while the flag is off.

        Ash field policies hide a field's value but do not stop a query from
        filtering on it, so `filter(salary > 100_000)` would still narrow the
        result set and leak the value a binary search at a time. With this on
        (the default), a matching read is forbidden outright instead.

        Set it to `false` if the field is safe to filter on and you only mean
        to hide it from responses.
        """
      ],
      description: [
        type: :string,
        doc: "Description used in policy breakdowns."
      ]
    ]
  }

  @feature_flags %Spark.Dsl.Section{
    name: :feature_flags,
    describe: """
    Declare feature flags, and gate actions and fields behind them.

    Guards are compiled into `Ash.Policy.Authorizer` policies and field
    policies, which is what makes them compose with `ash_authentication` — a
    flag guard is just one more condition that has to hold alongside your role
    and ownership rules.
    """,
    examples: [
      """
      feature_flags do
        provider {AshFeatureFlags.Provider.Flipt, base_url: "http://flipt:8080"}
        cache_ttl :timer.seconds(10)

        flag :new_checkout do
          default false
          enabled_for_roles [:admin]
        end

        flag :ml_pricing

        guard_action [:create, :update], flag: :new_checkout
        guard_attribute [:experimental_score], flag: :ml_pricing
      end
      """
    ],
    imports: [AshFeatureFlags.Checks.Builtins],
    entities: [@flag, @guard_action, @guard_attribute],
    no_depend_modules: [:provider],
    schema: [
      provider: [
        type: @provider_type,
        doc: """
        The flag backend for this resource. Falls back to
        `config :ash_feature_flags, provider: ...`, and finally to
        `AshFeatureFlags.Provider.Static`.
        """
      ],
      cache_ttl: [
        type: :non_neg_integer,
        doc:
          "Default cache TTL in milliseconds for flags on this resource. Defaults to `config :ash_feature_flags, cache_ttl: 5_000`."
      ],
      error_ttl: [
        type: :non_neg_integer,
        doc: """
        How long, in milliseconds, to cache the fallback value after a provider
        failure. Defaults to `0` — failures are not cached, so a brief blip
        cannot pin a flag to its fallback.

        Raise it when an outage would otherwise cost a fresh provider timeout
        on every guarded action and field of every request. Flags with `ttl 0`
        never cache failures regardless.
        """
      ],
      on_error: [
        type: {:one_of, [:default, :enable, :disable, :raise]},
        doc: """
        What to do when the provider errors:

          * `:default` (default) - use each flag's `default`
          * `:disable` - treat the flag as off
          * `:enable` - treat the flag as on
          * `:raise` - let the error propagate
        """
      ],
      policies?: [
        type: :boolean,
        default: true,
        doc: """
        Whether to compile guards into policies automatically.

        Set to `false` if you would rather write the checks by hand — the
        `flag_enabled/1` and `flag_variant/2` checks stay available either way.
        """
      ],
      unguarded_actions: [
        type: {:one_of, [:allow, :deny]},
        default: :allow,
        doc: """
        Only consulted when this extension adds `Ash.Policy.Authorizer` to a
        resource that did not have it.

        `:allow` (default) appends a catch-all policy so actions you did *not*
        guard behave exactly as they did before you added the extension.
        `:deny` leaves them to Ash's default, which forbids anything no policy
        authorizes — pick this if you intend to write full policies.
        """
      ]
    ]
  }

  @doc false
  def sections, do: [@feature_flags]
end
