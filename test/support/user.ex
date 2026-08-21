defmodule AshFeatureFlags.Test.User do
  @moduledoc """
  Stands in for an `ash_authentication` user resource.

  Deliberately *not* using `ash_authentication` — it is an optional
  integration, so the role plumbing and targeting keys have to work for plain
  Ash resources too. When it *is* present, `AshFeatureFlags.AshAuthentication`
  swaps the primary-key targeting key for the user's subject.
  """

  use Ash.Resource,
    domain: AshFeatureFlags.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :string, public?: true
    attribute :role, :atom, public?: true, constraints: [one_of: [:admin, :editor, :customer]]
    attribute :roles, {:array, :string}, public?: true, default: []
    attribute :tenant, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
