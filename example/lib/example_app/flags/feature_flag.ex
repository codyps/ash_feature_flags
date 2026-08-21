defmodule ExampleApp.Flags.FeatureFlag do
  @moduledoc """
  The database-backed flag table.

  `AshFeatureFlags.FlagStore` supplies every column and action — `key`,
  `enabled`, `rollout_percentage`, `allowed_roles`, `allowed_tenants`,
  `variant`, `metadata`, CRUD and a `by_key` read. All we bring is the data
  layer, which is why "SQLite or Postgres" is a two-line change:

      data_layer: AshPostgres.DataLayer

      postgres do
        table "feature_flags"
        repo ExampleApp.Repo
      end
  """

  use Ash.Resource,
    domain: ExampleApp.Flags,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshFeatureFlags.FlagStore]

  sqlite do
    table "feature_flags"
    repo ExampleApp.Repo
  end
end
