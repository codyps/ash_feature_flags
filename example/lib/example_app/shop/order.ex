defmodule ExampleApp.Shop.Order do
  @moduledoc """
  The flagged resource — the whole point of the example.

  Note what is *not* here: no `if flag_enabled?` sprinkled through actions, no
  custom changes, no plug. The `feature_flags` section declares the flags and
  the guards; the `policies` section states who may do what. Ash requires every
  applicable policy to pass, so the two AND together.

  Read the two blocks side by side:

    * a **customer** may `express_checkout` their own order — the flag is on
      and the ownership rule passes
    * a **support** agent may never `express_checkout`, no matter what the flag
      backend says. A flag guard vetoes; it cannot grant.
    * nobody may `add_gift_wrap`, because that flag is off — except an
      **admin**, via `enabled_for_roles [:admin]`, which short-circuits the
      backend. They still need a policy to authorize the action, which they
      have.
  """

  use Ash.Resource,
    domain: ExampleApp.Shop,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshFeatureFlags]

  sqlite do
    table "orders"
    repo ExampleApp.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :reference, :string, public?: true, allow_nil?: false
    attribute :total_cents, :integer, public?: true, allow_nil?: false, default: 0
    attribute :express?, :boolean, public?: true, allow_nil?: false, default: false
    attribute :gift_wrapped?, :boolean, public?: true, allow_nil?: false, default: false

    attribute :predicted_ltv, :integer,
      public?: true,
      description: "Model output. Hidden unless the ml-scoring flag is on."

    attribute :fraud_notes, :string,
      public?: true,
      description: "Internal review notes. Hidden unless fraud-tooling is on for you."

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :customer, ExampleApp.Accounts.User do
      public? true
      allow_nil? false
      attribute_writable? true
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    update :express_checkout do
      accept []
      require_atomic? false
      change set_attribute(:express?, true)
    end

    update :add_gift_wrap do
      accept []
      require_atomic? false
      change set_attribute(:gift_wrapped?, true)
    end
  end

  feature_flags do
    # No `provider` here: the demo sets it globally per run, so the exact same
    # resource is evaluated against Static, SQLite, Flipt and flagd in turn.
    # In a real app you would write, say:
    #
    #     provider {AshFeatureFlags.Provider.Flipt, base_url: "http://flipt:8080"}

    flag :express_checkout do
      description "One-tap checkout. Seeded ON in every backend."
    end

    flag :gift_wrapping do
      description "Seeded OFF in every backend, so the guard is seen vetoing."

      # Staff dogfooding: on for admins regardless of what the backend says.
      # This is what lets an admin use gift wrapping while it is still off.
      enabled_for_roles [:admin]
    end

    flag :ml_scoring do
      description "Expose model output on orders"
    end

    flag :fraud_tooling do
      description "Internal review notes; targeted at support in every backend"
    end

    flag :loyalty_pricing do
      description "Percentage rollout, to show bucketing is stable per user"
    end

    guard_action [:express_checkout], flag: :express_checkout

    guard_action [:add_gift_wrap],
      flag: :gift_wrapping,
      message: "Gift wrapping is not available yet."

    # Hidden *and* unfilterable: without the filter guard you could bisect the
    # value out with `filter(predicted_ltv > 500)`.
    guard_attribute [:predicted_ltv], flag: :ml_scoring

    # Hidden from responses, but safe to filter on.
    guard_attribute [:fraud_notes], flag: :fraud_tooling, prevent_filtering?: false
  end

  policies do
    # Pre-existing authorization rules. None of these mention feature flags.
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :support)
      authorize_if expr(customer_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :customer)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type([:update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if expr(customer_id == ^actor(:id))
    end
  end
end
