defmodule AshFeatureFlags.Flag do
  @moduledoc """
  The compile-time definition of a single feature flag, as declared in the
  `feature_flags` section of a resource (or in application config).

  You rarely build these by hand — they are produced by the DSL — but providers
  receive one on every evaluation, so the struct is public API.
  """

  defstruct [
    :name,
    :key,
    :description,
    :provider,
    :ttl,
    :on_error,
    :variant,
    default: false,
    enabled_for_roles: [],
    disabled_for_roles: [],
    context: %{},
    __identifier__: nil,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          key: String.t() | nil,
          description: String.t() | nil,
          provider: module() | {module(), keyword()} | nil,
          ttl: non_neg_integer() | nil,
          on_error: AshFeatureFlags.on_error() | nil,
          variant: String.t() | nil,
          default: boolean(),
          enabled_for_roles: [atom() | String.t()],
          disabled_for_roles: [atom() | String.t()],
          context: map()
        }

  @doc """
  The provider-facing key for a flag.

  Defaults to the dasherized flag name, since that is the convention used by
  Flipt, LaunchDarkly and flagd alike. Override it with `key "..."` when your
  provider-side key does not match.
  """
  @spec key(t()) :: String.t()
  def key(%__MODULE__{key: key}) when is_binary(key), do: key
  def key(%__MODULE__{name: name}), do: name |> to_string() |> String.replace("_", "-")

  @doc false
  @spec transform(t()) :: {:ok, t()}
  def transform(%__MODULE__{} = flag) do
    {:ok, %{flag | key: key(flag)}}
  end
end
