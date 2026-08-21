defmodule ExampleApp.Accounts.User do
  @moduledoc """
  The actor.

  In a real app this is your `ash_authentication` user resource — nothing here
  would change. `AshFeatureFlags` reads `role` off whatever actor you pass, and
  uses the `ash_authentication` subject as the targeting key when the package is
  present, falling back to the primary key as it does here.
  """

  use Ash.Resource,
    domain: ExampleApp.Accounts,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "users"
    repo ExampleApp.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :string, public?: true, allow_nil?: false

    attribute :role, :atom,
      public?: true,
      allow_nil?: false,
      default: :customer,
      constraints: [one_of: [:admin, :support, :customer]]
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  identities do
    identity :unique_email, [:email]
  end
end
