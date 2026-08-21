defmodule AshFeatureFlags do
  @moduledoc """
  Feature flags for Ash resources.

  Add the extension, declare flags, and guard actions and fields with them:

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

  `guard_action` compiles to a policy that vetoes the action while the flag is
  off; `guard_attribute` compiles to a field policy, so the field comes back as
  `%Ash.ForbiddenField{}` rather than its value. Both are ordinary Ash
  policies, which is what makes them compose with `ash_authentication` — see
  the "Working with ash_authentication" section below.

  ## Providers

  | Provider | Backend |
  | --- | --- |
  | `AshFeatureFlags.Provider.Flipt` | [Flipt](https://flipt.io) evaluation API |
  | `AshFeatureFlags.Provider.OpenFeature` | any OFREP server, e.g. flagd |
  | `AshFeatureFlags.Provider.LaunchDarkly` | LaunchDarkly, via `ldclient_erl` |
  | `AshFeatureFlags.Provider.AshResource` | a database table (Postgres, SQLite, ETS...) |
  | `AshFeatureFlags.Provider.Static` | compile-time/config values, for tests |

  Set a default in config and override per resource or per flag:

      config :ash_feature_flags,
        provider: {AshFeatureFlags.Provider.Flipt, base_url: "http://flipt:8080"},
        cache_ttl: :timer.seconds(5),
        on_error: :default

  ## Working with ash_authentication

  `ash_authentication` handles *who you are*; its roles and rules live in your
  policies. Because a flag guard is also a policy, the two AND together with no
  glue:

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

  An editor may publish only while `publishing_v2` is on; an admin gets the
  flag unconditionally but still needs a policy to authorize the action. Roles
  are read from the actor using `config :ash_feature_flags, role_keys: [:role,
  :roles]`, and a `ash_authentication` user's subject (`"user?id=..."`) becomes
  the targeting key, so percentage rollouts are stable per user across requests
  and nodes.

  To mix flags into policies you write yourself, import the checks:

      import AshFeatureFlags.Checks.Builtins

      policies do
        policy action_type(:read) do
          authorize_if actor_attribute_equals(:role, :admin)
          authorize_if flag_enabled(:public_catalogue)
        end
      end

  This works on any resource, with or without the extension.

  ## Outside of policies

  `enabled?/2` answers the same question anywhere — a LiveView, a controller,
  a background job:

      if AshFeatureFlags.enabled?(:new_checkout, actor: socket.assigns.current_user) do
        ...
      end
  """

  @type on_error :: :default | :enable | :disable | :raise

  use Spark.Dsl.Extension,
    sections: AshFeatureFlags.Dsl.sections(),
    transformers: [AshFeatureFlags.Transformers.AddPolicies],
    verifiers: [AshFeatureFlags.Verifiers.VerifyGuards],
    # Guards compile to policies, so the policy authorizer always comes along.
    # `AddPolicies` also registers it in `authorizers`.
    add_extensions: [Ash.Policy.Authorizer]

  alias AshFeatureFlags.{Context, Evaluator}

  @doc """
  Whether a flag is on.

  ## Options

    * `:actor` - the actor to evaluate for; roles, tenant and targeting key are
      derived from it
    * `:tenant` - overrides the actor's tenant
    * `:resource` - the resource whose `feature_flags` section declares the
      flag. Without it, the flag is looked up in
      `config :ash_feature_flags, :flags` and otherwise treated as
      default-off.
    * `:roles` - override the roles inferred from the actor
    * `:context` - extra key/values passed to the provider for targeting
    * `:provider`, `:ttl`, `:on_error` - per-call overrides

  ## Examples

      AshFeatureFlags.enabled?(:new_checkout, actor: current_user)

      AshFeatureFlags.enabled?(:ml_pricing,
        actor: current_user,
        resource: MyApp.Shop.Order,
        context: %{country: "NZ"}
      )
  """
  @spec enabled?(atom(), keyword()) :: boolean()
  def enabled?(flag, opts \\ []) when is_atom(flag) do
    Evaluator.enabled?(flag, Context.build(opts), opts)
  end

  @doc """
  Whether all (or, with `match: :any`, at least one) of several flags are on.
  """
  @spec all_enabled?([atom()], keyword()) :: boolean()
  def all_enabled?(flags, opts \\ []) when is_list(flags) do
    Evaluator.all?(flags, Context.build(opts), opts[:match] || :all, opts)
  end

  @doc """
  The variant of a multivariate flag.

  Returns `{:ok, variant}` or `{:error, reason}`; `nil` means the provider had
  no variant for this context.
  """
  @spec variant(atom(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def variant(flag, opts \\ []) when is_atom(flag) do
    Evaluator.variant(flag, Context.build(opts), opts)
  end

  @doc """
  Runs `fun` when the flag is on, otherwise returns `otherwise`.

      AshFeatureFlags.with_flag(:new_checkout, [actor: user], fn ->
        new_checkout(order)
      end, fn -> legacy_checkout(order) end)
  """
  @spec with_flag(atom(), keyword(), (-> result), (-> result)) :: result when result: term()
  def with_flag(flag, opts, fun, otherwise \\ fn -> nil end) do
    if enabled?(flag, opts), do: fun.(), else: otherwise.()
  end

  @doc """
  Drops cached evaluations — everything, or one flag's.

  Call this from a webhook when your flag backend reports a change, so you can
  run a comfortable TTL without waiting it out after every toggle.

      AshFeatureFlags.invalidate("new-checkout")
      AshFeatureFlags.invalidate()
  """
  @spec invalidate(String.t() | atom() | nil) :: :ok
  defdelegate invalidate(flag_key \\ nil), to: AshFeatureFlags.Cache, as: :clear
end
