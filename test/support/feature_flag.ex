defmodule AshFeatureFlags.Test.FeatureFlag do
  @moduledoc """
  The database-backed flag table, using the ETS data layer.

  In a real app this is `AshPostgres.DataLayer` or `AshSqlite.DataLayer` and a
  `postgres do ... end` / `sqlite do ... end` block; nothing else differs,
  which is the point of building the store on an Ash resource.
  """

  use Ash.Resource,
    domain: AshFeatureFlags.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshFeatureFlags.FlagStore]

  ets do
    private? true
  end

  # Declared here rather than taking the extension's default, because ETS
  # cannot check uniqueness natively. `add_new_identity` steps aside for it.
  identities do
    identity :unique_key, [:key], pre_check_with: AshFeatureFlags.Test.Domain
  end
end
