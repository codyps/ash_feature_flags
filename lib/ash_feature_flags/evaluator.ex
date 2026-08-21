defmodule AshFeatureFlags.Evaluator do
  @moduledoc """
  Resolves a flag to a value: definition → role short-circuits → cache →
  provider → error handling → telemetry.

  Everything in `AshFeatureFlags` that asks "is this on?" comes through here,
  so the answer a policy check gets and the answer `AshFeatureFlags.enabled?/2`
  gives are always the same.

  ## Telemetry

    * `[:ash_feature_flags, :evaluate, :start]` — measurements `%{system_time:}`
    * `[:ash_feature_flags, :evaluate, :stop]` — measurements `%{duration:}`,
      metadata `%{flag:, provider:, result:, source:}` where `source` is
      `:cache`, `:provider`, `:role`, `:default` or `:error`
    * `[:ash_feature_flags, :evaluate, :exception]` — a provider raised
  """

  require Logger

  alias AshFeatureFlags.{Cache, Context, Flag, Provider}

  @default_ttl 5_000

  @doc """
  Evaluates a single flag, returning a boolean.

  Never raises unless `on_error: :raise` is configured for the flag.
  """
  @spec enabled?(Flag.t() | atom(), Context.t(), keyword()) :: boolean()
  def enabled?(flag, context, opts \\ [])

  def enabled?(name, %Context{} = context, opts) when is_atom(name) do
    enabled?(resolve_flag(name, context, opts), context, opts)
  end

  def enabled?(%Flag{} = flag, %Context{} = context, opts) do
    case evaluate(flag, context, opts) do
      {:ok, value} -> value
      {:error, _reason} -> false
    end
  end

  @doc """
  Evaluates several flags together.

  `match` is `:all` (every flag must be on) or `:any` (at least one).
  """
  @spec all?([Flag.t() | atom()], Context.t(), :all | :any, keyword()) :: boolean()
  def all?(flags, context, match \\ :all, opts \\ [])

  def all?([], _context, :all, _opts), do: true
  def all?([], _context, :any, _opts), do: false

  def all?(flags, %Context{} = context, :all, opts),
    do: Enum.all?(flags, &enabled?(&1, context, opts))

  def all?(flags, %Context{} = context, :any, opts),
    do: Enum.any?(flags, &enabled?(&1, context, opts))

  @doc """
  Reads the flag's variant, for multivariate flags.
  """
  @spec variant(Flag.t() | atom(), Context.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def variant(name, %Context{} = context, opts) when is_atom(name) do
    variant(resolve_flag(name, context, opts), context, opts)
  end

  def variant(%Flag{} = flag, %Context{} = context, opts) do
    {provider, provider_opts} = provider_for(flag, context, opts)

    # `function_exported?/3` alone answers `false` for a module that has not
    # been loaded yet, which in interactive mode (dev, test, most releases) is
    # every provider we have not called into. Nothing else in this path would
    # autoload it, so a variant lookup would fail permanently on first use.
    if Code.ensure_loaded?(provider) and function_exported?(provider, :variant, 3) do
      key = {:variant, Context.cache_key(context, flag, {provider, provider_opts})}

      Cache.fetch(key, ttl_for(flag, context, opts), fn ->
        provider.variant(flag, context, provider_opts)
      end)
    else
      {:error,
       "#{inspect(provider)} does not implement variant/3, but flag #{inspect(flag.name)} was asked for one"}
    end
  end

  @doc """
  True if the flag's variant equals `expected`.
  """
  @spec variant?(Flag.t() | atom(), Context.t(), String.t(), keyword()) :: boolean()
  def variant?(flag, context, expected, opts \\ []) do
    case variant(flag, context, opts) do
      {:ok, value} -> to_string(value) == to_string(expected)
      {:error, _} -> false
    end
  end

  @doc """
  The full evaluation, returning `{:ok, boolean}` or `{:error, reason}`.
  """
  @spec evaluate(Flag.t(), Context.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def evaluate(%Flag{} = flag, %Context{} = context, opts \\ []) do
    metadata = %{flag: flag.name, key: Flag.key(flag), resource: context.resource}

    :telemetry.span([:ash_feature_flags, :evaluate], metadata, fn ->
      {result, source, provider} = do_evaluate(flag, context, opts)
      {result, Map.merge(metadata, %{result: result, source: source, provider: provider})}
    end)
  end

  defp do_evaluate(flag, context, opts) do
    cond do
      # An explicit deny list beats everything, including the provider. This is
      # how you keep an experiment away from a role no matter what marketing
      # toggled this morning.
      flag.disabled_for_roles != [] and Context.has_any_role?(context, flag.disabled_for_roles) ->
        {{:ok, false}, :role, nil}

      flag.enabled_for_roles != [] and Context.has_any_role?(context, flag.enabled_for_roles) ->
        {{:ok, true}, :role, nil}

      true ->
        evaluate_with_provider(flag, context, opts)
    end
  end

  defp evaluate_with_provider(flag, context, opts) do
    {provider, provider_opts} = provider_for(flag, context, opts)
    key = Context.cache_key(context, flag, {provider, provider_opts})
    ttl = ttl_for(flag, context, opts)

    source = if ttl > 0 and match?({:ok, _}, Cache.get(key)), do: :cache, else: :provider

    result =
      Cache.fetch(key, ttl, fn ->
        case flag.variant do
          nil ->
            provider.enabled?(flag, context, provider_opts)

          expected ->
            with {:ok, variant} <- provider.variant(flag, context, provider_opts) do
              {:ok, to_string(variant) == to_string(expected)}
            end
        end
      end)

    case result do
      {:ok, value} when is_boolean(value) ->
        {{:ok, value}, source, provider}

      {:ok, other} ->
        {fallback(flag, context, opts, {:invalid_value, other}, provider, key, ttl), :error,
         provider}

      {:error, reason} ->
        {fallback(flag, context, opts, reason, provider, key, ttl), :error, provider}
    end
  rescue
    exception ->
      {provider, _} = provider_for(flag, context, opts)
      {handle_error(flag, context, opts, exception, provider), :error, provider}
  end

  # Failures are not cached by default: a one-second blip should not pin a flag
  # to its fallback for the rest of the TTL. But an outage then costs a fresh
  # provider timeout on *every* guarded action and field of every request,
  # which is when the cache is needed most — so `error_ttl` lets you cache the
  # fallback briefly. A flag with caching switched off (`ttl 0`, the kill
  # switch case) never caches its failures either.
  defp fallback(flag, context, opts, reason, provider, key, ttl) do
    result = handle_error(flag, context, opts, reason, provider)

    with true <- ttl > 0,
         error_ttl when error_ttl > 0 <- error_ttl(flag, context, opts),
         {:ok, value} <- result do
      Cache.put(key, value, error_ttl)
    end

    result
  end

  defp handle_error(flag, context, opts, reason, provider) do
    case on_error(flag, context, opts) do
      :raise ->
        raise AshFeatureFlags.Error.ProviderError,
          flag: flag.name,
          provider: provider,
          reason: reason

      strategy ->
        Logger.warning(fn ->
          "[ash_feature_flags] #{inspect(provider)} failed to evaluate #{inspect(flag.name)}: " <>
            inspect(reason) <> " — falling back to #{inspect(strategy)}"
        end)

        case strategy do
          :enable -> {:ok, true}
          :disable -> {:ok, false}
          :default -> {:ok, flag.default}
        end
    end
  end

  ## Configuration resolution
  #
  # Every knob resolves the same way: flag → resource section → application
  # config → built-in default. That means you can set a sane global default and
  # only override where it matters.

  @doc false
  @spec resolve_flag(atom(), Context.t(), keyword()) :: Flag.t()
  def resolve_flag(name, %Context{} = context, opts \\ []) do
    with :error <- flag_from_opts(name, opts),
         :error <- flag_from_resource(name, context.resource),
         :error <- flag_from_config(name) do
      %Flag{name: name, key: Flag.key(%Flag{name: name})}
    else
      {:ok, flag} -> flag
    end
  end

  defp flag_from_opts(_name, opts) do
    case opts[:definition] do
      %Flag{} = flag -> {:ok, flag}
      _ -> :error
    end
  end

  defp flag_from_resource(name, resource) when is_atom(resource) and not is_nil(resource) do
    AshFeatureFlags.Info.flag(resource, name)
  end

  defp flag_from_resource(_name, _resource), do: :error

  defp flag_from_config(name) do
    case Application.get_env(:ash_feature_flags, :flags, [])[name] do
      nil ->
        :error

      config when is_list(config) ->
        {:ok, struct(Flag, Keyword.put(config, :name, name)) |> then(&%{&1 | key: Flag.key(&1)})}

      config when is_boolean(config) ->
        {:ok, %Flag{name: name, key: Flag.key(%Flag{name: name}), default: config}}
    end
  end

  @doc false
  @spec provider_for(Flag.t(), Context.t(), keyword()) :: {module(), keyword()}
  def provider_for(%Flag{} = flag, %Context{} = context, opts \\ []) do
    resource_provider =
      if context.resource, do: AshFeatureFlags.Info.provider(context.resource), else: nil

    flag.provider
    |> Provider.merge(opts[:provider])
    |> Provider.merge(resource_provider)
    |> Provider.merge(Application.get_env(:ash_feature_flags, :provider))
    |> Kernel.||(AshFeatureFlags.Provider.Static)
    |> Provider.split()
  end

  defp ttl_for(flag, context, opts) do
    flag.ttl ||
      opts[:ttl] ||
      (context.resource && AshFeatureFlags.Info.cache_ttl(context.resource)) ||
      Application.get_env(:ash_feature_flags, :cache_ttl, @default_ttl)
  end

  defp error_ttl(_flag, context, opts) do
    opts[:error_ttl] ||
      (context.resource && AshFeatureFlags.Info.error_ttl(context.resource)) ||
      Application.get_env(:ash_feature_flags, :error_ttl, 0)
  end

  defp on_error(flag, context, opts) do
    flag.on_error ||
      opts[:on_error] ||
      (context.resource && AshFeatureFlags.Info.on_error(context.resource)) ||
      Application.get_env(:ash_feature_flags, :on_error, :default)
  end
end
