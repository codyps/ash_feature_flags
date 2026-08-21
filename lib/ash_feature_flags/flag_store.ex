defmodule AshFeatureFlags.FlagStore do
  @moduledoc """
  Turns one of your own Ash resources into a feature flag table.

  Use this when you want flags in your own database rather than a third-party
  service — the data layer is yours, so the same extension gives you Postgres,
  SQLite, or an ETS table in tests:

      defmodule MyApp.Flags.FeatureFlag do
        use Ash.Resource,
          domain: MyApp.Flags,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshFeatureFlags.FlagStore]

        postgres do
          table "feature_flags"
          repo MyApp.Repo
        end
      end

  Swap `AshPostgres.DataLayer` for `AshSqlite.DataLayer` (and the `sqlite do`
  block) and nothing else changes. Then point the provider at it:

      config :ash_feature_flags,
        provider: {AshFeatureFlags.Provider.AshResource,
                   resource: MyApp.Flags.FeatureFlag}

  ## What gets added

  | Field | Type | Meaning |
  | --- | --- | --- |
  | `key` | `:string` | the flag key, unique |
  | `enabled` | `:boolean` | the master switch |
  | `description` | `:string` | free text |
  | `rollout_percentage` | `:integer` | 0–100; hashes the actor's targeting key |
  | `allowed_roles` | `{:array, :string}` | on for these roles regardless of rollout |
  | `allowed_tenants` | `{:array, :string}` | restricts the flag to these tenants |
  | `variant` | `:string` | value returned for multivariate flags |
  | `metadata` | `:map` | yours |

  Plus `:read`, `:create`, `:update`, `:destroy` actions, a `by_key` read, an
  `identity :unique_key`, and timestamps. Every attribute and action is added
  with `add_new_*`, so declaring your own `key` attribute or `create` action in
  the resource wins over ours.

  ## Authorization

  This resource holds the switches for everything else, so it deserves its own
  policies. It is added without an authorizer; add yours:

      policies do
        policy always() do
          authorize_if actor_attribute_equals(:role, :admin)
        end
      end

  `AshFeatureFlags.Provider.AshResource` reads with `authorize?: false` by
  default, since a policy check running inside another policy check would be a
  cycle. Set `authorize_reads?: true` on the provider if you need otherwise.
  """

  @sections []

  use Spark.Dsl.Extension,
    sections: @sections,
    transformers: [AshFeatureFlags.FlagStore.Transformers.AddFlagFields]
end
