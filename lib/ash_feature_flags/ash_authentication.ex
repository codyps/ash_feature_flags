defmodule AshFeatureFlags.AshAuthentication do
  @moduledoc """
  The one place that knows about `ash_authentication`.

  `ash_authentication` is integrated with but never depended on — it is
  resolved at runtime so this library compiles and runs identically whether or
  not you use it. All the indirection lives here rather than scattered through
  the code.

  What we take from it: the *subject* of a user resource — the
  `"user?id=8e2b..."` string it already uses to identify a user in tokens and
  sessions. Using the same identifier as the targeting key means a percentage
  rollout picks the same users in your flag backend as your session does, and
  stays stable across nodes and restarts.
  """

  @info Module.concat(["AshAuthentication", "Info"])
  @root Module.concat(["AshAuthentication"])

  @doc "Whether `ash_authentication` is available in this application."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(@root)

  @doc """
  Whether the module is a user resource managed by `ash_authentication`.
  """
  @spec user_resource?(module()) :: boolean()
  def user_resource?(resource) do
    available?() and Code.ensure_loaded?(@info) and
      function_exported?(@info, :authentication_subject_name, 1) and
      match?({:ok, _}, apply(@info, :authentication_subject_name, [resource]))
  rescue
    _ -> false
  end

  @doc """
  The `ash_authentication` subject for a user record, or `nil`.
  """
  @spec subject(struct()) :: String.t() | nil
  def subject(%resource{} = record) do
    if user_resource?(resource) do
      apply(@root, :user_to_subject, [record])
    end
  rescue
    _ -> nil
  end

  def subject(_record), do: nil
end
