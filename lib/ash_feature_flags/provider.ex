defmodule AshFeatureFlags.Provider do
  @moduledoc """
  The behaviour every flag backend implements.

  A provider is a plain module plus a keyword list of options, so the same
  module can be pointed at two different Flipt namespaces or LaunchDarkly
  environments on different resources:

      feature_flags do
        provider {AshFeatureFlags.Provider.Flipt, namespace: "billing"}
      end

  Built-in providers:

    * `AshFeatureFlags.Provider.Static` — flags from config, ideal for tests
    * `AshFeatureFlags.Provider.Flipt` — Flipt's evaluation API
    * `AshFeatureFlags.Provider.OpenFeature` — OFREP (flagd and friends)
    * `AshFeatureFlags.Provider.LaunchDarkly` — LaunchDarkly ("Darkly")
    * `AshFeatureFlags.Provider.AshResource` — a database table (Postgres,
      SQLite, ETS, anything with an Ash data layer)

  ## Writing your own

      defmodule MyApp.Flags.Provider do
        @behaviour AshFeatureFlags.Provider

        @impl true
        def enabled?(flag, context, _opts) do
          {:ok, MyApp.Flags.on?(AshFeatureFlags.Flag.key(flag), context.targeting_key)}
        end
      end

  Returning `{:error, reason}` hands control to the configured `on_error`
  behaviour rather than crashing the request.
  """

  alias AshFeatureFlags.{Context, Flag}

  @typedoc "Provider module, or module with options"
  @type ref :: module() | {module(), keyword()}

  @doc """
  Whether the flag is on for this context.
  """
  @callback enabled?(Flag.t(), Context.t(), keyword()) :: {:ok, boolean()} | {:error, term()}

  @doc """
  The variant (multivariate value) of the flag for this context.

  Only needed if you use `variant:` on a guard or `AshFeatureFlags.variant/2`.
  """
  @callback variant(Flag.t(), Context.t(), keyword()) ::
              {:ok, String.t() | nil} | {:error, term()}

  @doc """
  Validates and normalizes provider options at configuration time.
  """
  @callback init(keyword()) :: {:ok, keyword()} | {:error, term()}

  @doc """
  A child spec, if the provider needs a process (a poller, an SDK client...).

  Returned specs are started under `AshFeatureFlags.Supervisor` when the
  provider is listed in `config :ash_feature_flags, providers: [...]`.
  """
  @callback child_spec(keyword()) :: Supervisor.child_spec() | nil

  @doc """
  Writes a flag value, for providers that support it (`Static`, `AshResource`).
  """
  @callback put(Flag.t(), boolean() | String.t(), keyword()) :: :ok | {:error, term()}

  @optional_callbacks variant: 3, init: 1, child_spec: 1, put: 3

  @doc """
  Splits a provider reference into `{module, opts}`.
  """
  @spec split(ref()) :: {module(), keyword()}
  def split({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  def split(module) when is_atom(module), do: {module, []}

  @doc """
  Merges a provider reference over a default one.

  A per-flag `provider {Flipt, namespace: "x"}` overrides the resource-level
  provider entirely; a per-flag `provider Flipt` when the resource already says
  `provider {Flipt, namespace: "x"}` keeps the options.
  """
  @spec merge(ref() | nil, ref() | nil) :: ref() | nil
  def merge(nil, default), do: default
  def merge(override, nil), do: override

  def merge(override, default) do
    {override_module, override_opts} = split(override)
    {default_module, default_opts} = split(default)

    if override_module == default_module do
      {override_module, Keyword.merge(default_opts, override_opts)}
    else
      {override_module, override_opts}
    end
  end
end
