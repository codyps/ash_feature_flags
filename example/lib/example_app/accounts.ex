defmodule ExampleApp.Accounts do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource ExampleApp.Accounts.User
  end
end
