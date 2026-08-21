defmodule ExampleApp.Shop do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ExampleApp.Shop.Order
  end
end
