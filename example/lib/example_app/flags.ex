defmodule ExampleApp.Flags do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ExampleApp.Flags.FeatureFlag
  end
end
