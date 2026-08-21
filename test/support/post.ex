defmodule AshFeatureFlags.Test.Post do
  @moduledoc """
  A resource with both kinds of guard *and* its own policies, so the tests can
  show that a flag guard ANDs with an existing role rule rather than replacing
  it.
  """

  use Ash.Resource,
    domain: AshFeatureFlags.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshFeatureFlags]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true, allow_nil?: false
    attribute :body, :string, public?: true
    attribute :predicted_engagement, :float, public?: true
    attribute :internal_notes, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    update :publish do
      accept []
      change set_attribute(:body, "published")
      require_atomic? false
    end
  end

  feature_flags do
    flag :publishing_v2 do
      description "The rewritten publishing pipeline"
      enabled_for_roles [:admin]
    end

    flag :ml_scoring

    flag :support_tooling do
      default false
    end

    guard_action [:publish], flag: :publishing_v2
    guard_action [:create], flag: :publishing_v2, message: "Post creation is paused"
    guard_attribute [:predicted_engagement], flag: :ml_scoring
    guard_attribute [:internal_notes], flag: :support_tooling
  end

  policies do
    # The pre-existing rule: only editors and admins may touch posts.
    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :editor)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:read) do
      authorize_if always()
    end
  end
end
