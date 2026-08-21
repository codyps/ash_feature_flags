defmodule AshFeatureFlags.Test.Comment do
  @moduledoc """
  A resource with *no* `feature_flags` section, using the checks by hand.

  This is the escape hatch: `flag_enabled/1` and friends are ordinary policy
  checks, so they compose with role rules in whatever shape you need — here,
  "admins always, everyone else only while the flag is on", which is an OR and
  therefore cannot be expressed as a guard.
  """

  use Ash.Resource,
    domain: AshFeatureFlags.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  import AshFeatureFlags.Checks.Builtins

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :body, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  policies do
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if flag_enabled(:public_commenting)
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:update, :destroy]) do
      # A kill switch reads better as a forbid than as a guard.
      forbid_if flag_enabled(:comments_frozen)
      authorize_if always()
    end
  end

  field_policies do
    field_policy :body do
      authorize_if flag_variant(:comment_rendering, "rich")
    end

    field_policy :* do
      authorize_if always()
    end
  end
end
