defmodule AshFeatureFlags.Test.Domain do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshFeatureFlags.Test.User
    resource AshFeatureFlags.Test.AuthUser
    resource AshFeatureFlags.Test.Post
    resource AshFeatureFlags.Test.Comment
    resource AshFeatureFlags.Test.Note
    resource AshFeatureFlags.Test.StrictNote
    resource AshFeatureFlags.Test.FeatureFlag
  end
end
