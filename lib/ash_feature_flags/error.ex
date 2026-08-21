defmodule AshFeatureFlags.Error.ProviderError do
  @moduledoc """
  Raised when a provider fails and the flag is configured with `on_error :raise`.

  The default is `on_error :default`, which falls back to the flag's declared
  default and logs — a flag backend being down should not take your app with
  it. Use `:raise` only for flags where guessing is worse than failing.
  """

  defexception [:flag, :provider, :reason]

  @impl Exception
  def message(%{flag: flag, provider: provider, reason: reason}) do
    """
    Feature flag #{inspect(flag)} could not be evaluated.

    Provider: #{inspect(provider)}
    Reason:   #{inspect(reason)}
    """
  end
end

defmodule AshFeatureFlags.Error.FlagDisabled do
  @moduledoc """
  The `Ash.Error.Forbidden` sub-error surfaced when a flag-guarded action is
  attempted while its flag is off.
  """

  use Splode.Error, fields: [:flag, :action, :resource, :custom_message], class: :forbidden

  @impl Exception
  def message(%{custom_message: custom_message}) when is_binary(custom_message),
    do: custom_message

  def message(%{flag: flag, action: action, resource: resource}) do
    "Action #{inspect(action)} on #{inspect(resource)} is behind feature flag #{inspect(flag)}, which is off."
  end
end
