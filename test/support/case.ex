defmodule AshFeatureFlags.Case do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      import AshFeatureFlags.Case

      alias AshFeatureFlags.Test.{Domain, FeatureFlag, Note, Post, StrictNote, User}
    end
  end

  setup do
    # Overrides and cache are global, so every test starts from a clean slate
    # and nothing here may run async.
    AshFeatureFlags.Provider.Static.reset()
    on_exit(&AshFeatureFlags.Provider.Static.reset/0)
    :ok
  end

  @doc "Turns a flag on or off for the duration of the test."
  def set_flag(key, value) do
    AshFeatureFlags.Provider.Static.put(key, value)
  end

  @doc "Builds an unpersisted actor; nothing here reads users from storage."
  def actor(attrs \\ []) do
    struct(
      AshFeatureFlags.Test.User,
      Keyword.merge([id: Ash.UUID.generate(), email: "someone@example.com"], attrs)
    )
  end
end
