defmodule ExampleApp.Providers do
  @moduledoc """
  The four backends, and how to get the same flag state into each.

  The demo runs an identical scenario matrix against every provider, which only
  works if they all start from the same state. That state is:

  | flag | intended state |
  | --- | --- |
  | `express-checkout` | on for everyone |
  | `gift-wrapping` | off for everyone |
  | `ml-scoring` | off for everyone |
  | `fraud-tooling` | on only for actors whose roles include `support` |
  | `loyalty-pricing` | on for 50% of actors, bucketed by targeting key |

  Each backend expresses that in its own idiom, which is half the point of
  reading this file:

    * `Static` — a map, with a function for the role rule
    * `AshResource` — rows, using `allowed_roles` and `rollout_percentage`
    * `Flipt` — segments and rollouts in `docker/flipt/features.yml`
    * `OpenFeature` — JsonLogic targeting in `docker/flagd/flags.json`

  The last two are seeded declaratively by the containers at boot, so `seed/1`
  is a no-op for them; it verifies reachability instead.
  """

  require Ash.Query

  alias AshFeatureFlags.Provider

  @type name :: :static | :sqlite | :flipt | :flagd

  @names [:static, :sqlite, :flipt, :flagd]

  @doc "Every provider the demo knows about."
  @spec names() :: [name()]
  def names, do: @names

  @doc "Providers that need no external service."
  @spec offline_names() :: [name()]
  def offline_names, do: [:static, :sqlite]

  @doc """
  Whether `put/3` can flip a flag at runtime.

  Flipt and flagd read `docker/` at boot, so the only way to change them is to
  edit the file and restart the container. The playground greys their toggles
  out rather than pretending.
  """
  @spec writable?(name()) :: boolean()
  def writable?(name), do: name in [:static, :sqlite]

  @doc "A human label, including where the backend lives."
  @spec label(name()) :: String.t()
  def label(:static), do: "Static (in-memory, from config)"
  def label(:sqlite), do: "AshResource (SQLite table via AshFeatureFlags.FlagStore)"
  def label(:flipt), do: "Flipt (#{url(:flipt)})"
  def label(:flagd), do: "OpenFeature / OFREP (#{url(:flagd)})"

  @doc "The `{module, opts}` to hand to `AshFeatureFlags`."
  @spec ref(name(), keyword()) :: Provider.ref()
  def ref(name, opts \\ [])

  def ref(:static, _opts), do: AshFeatureFlags.Provider.Static

  def ref(:sqlite, _opts),
    do: {AshFeatureFlags.Provider.AshResource, resource: ExampleApp.Flags.FeatureFlag}

  def ref(:flipt, _opts) do
    {AshFeatureFlags.Provider.Flipt,
     base_url: url(:flipt),
     namespace: Application.get_env(:example_app, :flipt_namespace, "default"),
     receive_timeout: 2_000}
  end

  def ref(:flagd, _opts) do
    {AshFeatureFlags.Provider.OpenFeature, base_url: url(:flagd), receive_timeout: 2_000}
  end

  @doc """
  Makes this provider the one every resource evaluates against.

  Pass `base_url:` to point an HTTP provider somewhere else — that is how
  `mix demo --stub` redirects Flipt and flagd at the loopback server. It is
  stored rather than passed along so that `label/1` and `reachable/1` report
  the address actually in use.
  """
  @spec activate(name(), keyword()) :: :ok
  def activate(name, opts \\ []) do
    if base_url = opts[:base_url] do
      Application.put_env(:example_app, url_key(name), base_url)
    end

    Application.put_env(:ash_feature_flags, :provider, ref(name, opts))
    AshFeatureFlags.invalidate()
    :ok
  end

  defp url_key(:flipt), do: :flipt_url
  defp url_key(:flagd), do: :flagd_url
  defp url_key(_name), do: :unused_url

  defp url(:flipt), do: Application.get_env(:example_app, :flipt_url, "http://localhost:8080")
  defp url(:flagd), do: Application.get_env(:example_app, :flagd_url, "http://localhost:8016")

  ## Seeding

  @doc """
  Puts the backend into the state the scenarios expect.

  Returns `:ok`, or `{:error, reason}` when a service is unreachable — the demo
  turns that into "start docker compose" rather than a stack trace.
  """
  @spec seed(name()) :: :ok | {:error, term()}
  def seed(:static) do
    AshFeatureFlags.Provider.Static.reset()

    AshFeatureFlags.Provider.Static.put("express-checkout", true)
    AshFeatureFlags.Provider.Static.put("gift-wrapping", false)
    AshFeatureFlags.Provider.Static.put("ml-scoring", false)

    # Static values may be functions of the evaluation context, which is how
    # you express a targeting rule without a real backend.
    AshFeatureFlags.Provider.Static.put("fraud-tooling", fn context ->
      :support in context.roles
    end)

    AshFeatureFlags.Provider.Static.put("loyalty-pricing", fn context ->
      bucket(context.targeting_key, "loyalty-pricing") < 50
    end)

    :ok
  end

  def seed(:sqlite) do
    upsert("express-checkout", enabled: true)
    upsert("gift-wrapping", enabled: false)
    upsert("ml-scoring", enabled: false)
    upsert("fraud-tooling", enabled: true, allowed_roles: ["support"], rollout_percentage: 0)
    upsert("loyalty-pricing", enabled: true, rollout_percentage: 50)

    AshFeatureFlags.invalidate()
    :ok
  end

  # Flipt and flagd read their state from the files in `docker/`, so there is
  # nothing to write — but there is something to check.
  def seed(name) when name in [:flipt, :flagd] do
    reachable(name)
  end

  @doc """
  Checks that an HTTP-backed provider answers, so the demo can explain itself.
  """
  @spec reachable(name()) :: :ok | {:error, term()}
  def reachable(name) when name in [:flipt, :flagd] do
    context = AshFeatureFlags.Context.build([])
    flag = %AshFeatureFlags.Flag{name: :express_checkout, key: "express-checkout"}
    {module, opts} = Provider.split(ref(name))

    case module.enabled?(flag, context, opts) do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  def reachable(_name), do: :ok

  @doc """
  Flips a flag, for the backends that can be written to at runtime.

  Used by the "toggling" section of the demo. Flipt and flagd are seeded
  declaratively here, so they report `:unsupported` and that section is skipped
  rather than faked.
  """
  @spec put(name(), String.t(), boolean()) :: :ok | :unsupported
  def put(:static, key, value) do
    AshFeatureFlags.Provider.Static.put(key, value)
    :ok
  end

  def put(:sqlite, key, value) do
    upsert(key, enabled: value)
    AshFeatureFlags.invalidate(key)
    :ok
  end

  def put(_name, _key, _value), do: :unsupported

  ## SQLite helpers

  defp upsert(key, attrs) do
    attrs = Map.new(attrs)

    existing =
      ExampleApp.Flags.FeatureFlag
      |> Ash.Query.for_read(:by_key, %{key: key})
      |> Ash.read_one(authorize?: false)

    case existing do
      {:ok, nil} ->
        ExampleApp.Flags.FeatureFlag
        |> Ash.Changeset.for_create(:create, Map.put(attrs, :key, key))
        |> Ash.create!(authorize?: false)

      {:ok, record} ->
        record
        |> Ash.Changeset.for_update(:update, attrs)
        |> Ash.update!(authorize?: false)
    end
  end

  # Mirrors the bucketing in `AshFeatureFlags.Provider.AshResource`, so the
  # Static backend puts the same users in the same cohort.
  defp bucket(targeting_key, flag_key) do
    :erlang.phash2({flag_key, targeting_key || "anonymous"}, 100)
  end
end
