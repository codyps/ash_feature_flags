defmodule AshFeatureFlags.Info do
  @moduledoc """
  Introspection for the `feature_flags` section.

  Every function accepts a resource module or a DSL state, and every function
  is safe to call on a resource that does not have the extension — you get
  `nil` or `[]` rather than an error. That is what lets the policy checks be
  used on any resource.
  """

  alias AshFeatureFlags.{ActionGuard, AttributeGuard, Flag}
  alias Spark.Dsl.Extension

  @type dsl :: module() | Spark.Dsl.t()

  @doc "All flags declared on the resource."
  @spec flags(dsl()) :: [Flag.t()]
  def flags(dsl) do
    dsl |> entities() |> Enum.filter(&is_struct(&1, Flag))
  end

  @doc "Looks up a single flag by name."
  @spec flag(dsl(), atom()) :: {:ok, Flag.t()} | :error
  def flag(dsl, name) do
    case Enum.find(flags(dsl), &(&1.name == name)) do
      nil -> :error
      flag -> {:ok, flag}
    end
  end

  @doc "All `guard_action` declarations."
  @spec action_guards(dsl()) :: [ActionGuard.t()]
  def action_guards(dsl) do
    dsl |> entities() |> Enum.filter(&is_struct(&1, ActionGuard))
  end

  @doc "All `guard_attribute` declarations."
  @spec attribute_guards(dsl()) :: [AttributeGuard.t()]
  def attribute_guards(dsl) do
    dsl |> entities() |> Enum.filter(&is_struct(&1, AttributeGuard))
  end

  @doc "The resource-level provider, if one is configured."
  @spec provider(dsl()) :: AshFeatureFlags.Provider.ref() | nil
  def provider(dsl), do: opt(dsl, :provider)

  @doc "The resource-level cache TTL in milliseconds, if set."
  @spec cache_ttl(dsl()) :: non_neg_integer() | nil
  def cache_ttl(dsl), do: opt(dsl, :cache_ttl)

  @doc "How long a provider failure's fallback value is cached, if set."
  @spec error_ttl(dsl()) :: non_neg_integer() | nil
  def error_ttl(dsl), do: opt(dsl, :error_ttl)

  @doc "The resource-level error strategy, if set."
  @spec on_error(dsl()) :: AshFeatureFlags.on_error() | nil
  def on_error(dsl), do: opt(dsl, :on_error)

  @doc "Whether guards are compiled into policies for this resource."
  @spec policies?(dsl()) :: boolean()
  def policies?(dsl), do: opt(dsl, :policies?, true)

  @doc "How to treat actions with no guard when we add the authorizer ourselves."
  @spec unguarded_actions(dsl()) :: :allow | :deny
  def unguarded_actions(dsl), do: opt(dsl, :unguarded_actions, :allow)

  @doc "Whether the resource uses this extension at all."
  @spec extension?(dsl()) :: boolean()
  def extension?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0) and
      AshFeatureFlags in Spark.extensions(module)
  rescue
    _ -> false
  end

  def extension?(dsl) when is_map(dsl) do
    AshFeatureFlags in Spark.Dsl.Transformer.get_persisted(dsl, :extensions, [])
  end

  def extension?(_), do: false

  defp entities(dsl) do
    if usable?(dsl) do
      Extension.get_entities(dsl, [:feature_flags]) || []
    else
      []
    end
  rescue
    _ -> []
  end

  defp opt(dsl, name, default \\ nil) do
    if usable?(dsl) do
      Extension.get_opt(dsl, [:feature_flags], name, default, false)
    else
      default
    end
  rescue
    _ -> default
  end

  # DSL states are always inspectable; modules only are once they've been
  # compiled with this extension.
  defp usable?(dsl) when is_map(dsl), do: true
  defp usable?(dsl) when is_atom(dsl), do: extension?(dsl)
  defp usable?(_), do: false
end
