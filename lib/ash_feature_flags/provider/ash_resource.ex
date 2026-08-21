defmodule AshFeatureFlags.Provider.AshResource do
  @moduledoc """
  Reads flags from a database table, via an Ash resource.

  Pair it with `AshFeatureFlags.FlagStore`, which gives your resource the
  standard columns:

      defmodule MyApp.Flags.FeatureFlag do
        use Ash.Resource,
          domain: MyApp.Flags,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshFeatureFlags.FlagStore]

        postgres do
          table "feature_flags"
          repo MyApp.Repo
        end
      end

      config :ash_feature_flags,
        provider: {AshFeatureFlags.Provider.AshResource,
                   resource: MyApp.Flags.FeatureFlag}

  Because it is an ordinary Ash resource, "Postgres or SQLite" is a data layer
  choice and nothing here changes. `AshSqlite.DataLayer` works the same, and
  `Ash.DataLayer.Ets` gives you an in-memory table for tests.

  ## Options

    * `:resource` (required) — the flag resource
    * `:domain` — the domain to call through; defaults to the resource's own
    * `:read_action` — defaults to `:by_key` if the resource has one, else the
      primary read with a filter applied
    * `:authorize_reads?` — defaults to `false`. Flag lookups run *inside*
      policy checks, so authorizing them would recurse. Turn it on only if the
      flag resource's policies are independent of feature flags.
    * `:tenant` — a fixed tenant for the lookup, when the flag table is not
      multitenant but your app is

  ## Evaluation

  A row is on when, in order:

    1. `enabled` is false → off, always. The master switch wins.
    2. `allowed_tenants` is non-empty and the actor's tenant is not in it → off
    3. the actor holds one of `allowed_roles` → on, skipping the rollout
    4. `rollout_percentage` is set → on if the actor's targeting key hashes
       below it. The hash is stable, so a user does not flip between requests,
       and it is salted with the flag key, so two 20% flags do not hit the
       same 20% of users.
    5. otherwise → on

  A row that does not exist is reported as `{:error, :flag_not_found}`, which
  routes through the flag's `on_error` and lands on its declared `default` —
  so adding `flag :new_thing` to a resource before inserting the row leaves it
  off rather than crashing.
  """

  @behaviour AshFeatureFlags.Provider

  require Ash.Query

  alias AshFeatureFlags.{Context, Flag}

  @impl AshFeatureFlags.Provider
  def init(opts) do
    if opts[:resource] do
      {:ok, opts}
    else
      {:error, "#{inspect(__MODULE__)} requires a `:resource` option"}
    end
  end

  @impl AshFeatureFlags.Provider
  def enabled?(%Flag{} = flag, %Context{} = context, opts) do
    with {:ok, record} <- fetch(flag, opts) do
      {:ok, evaluate(record, flag, context)}
    end
  end

  @impl AshFeatureFlags.Provider
  def variant(%Flag{} = flag, %Context{} = context, opts) do
    with {:ok, record} <- fetch(flag, opts) do
      if evaluate(record, flag, context) do
        {:ok, Map.get(record, :variant)}
      else
        {:ok, nil}
      end
    end
  end

  @impl AshFeatureFlags.Provider
  def put(%Flag{} = flag, value, opts) do
    with {:ok, resource} <- fetch_resource(opts),
         {:ok, record} <- fetch(flag, opts) do
      changes =
        case value do
          value when is_boolean(value) -> %{enabled: value}
          variant when is_binary(variant) -> %{enabled: true, variant: variant}
        end

      record
      |> Ash.Changeset.for_update(update_action(resource), changes, call_opts(opts))
      |> Ash.update()
      |> case do
        {:ok, _record} ->
          AshFeatureFlags.Cache.clear(Flag.key(flag))
          :ok

        {:error, error} ->
          {:error, error}
      end
    end
  end

  ## Lookup

  defp fetch(flag, opts) do
    with {:ok, resource} <- fetch_resource(opts) do
      key = Flag.key(flag)

      resource
      |> query_for(key, opts)
      |> Ash.read_one(call_opts(opts))
      |> case do
        {:ok, nil} -> {:error, {:flag_not_found, key}}
        {:ok, record} -> {:ok, record}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp query_for(resource, key, opts) do
    action = opts[:read_action] || default_read_action(resource)

    if action == :by_key do
      Ash.Query.for_read(resource, :by_key, %{key: key})
    else
      resource
      |> Ash.Query.new()
      |> Ash.Query.filter(key == ^key)
      |> then(fn query ->
        if action, do: Ash.Query.for_read(query, action, %{}), else: query
      end)
    end
  end

  defp default_read_action(resource) do
    if Ash.Resource.Info.action(resource, :by_key), do: :by_key, else: nil
  end

  defp update_action(resource) do
    case Ash.Resource.Info.primary_action(resource, :update) do
      %{name: name} -> name
      _ -> :update
    end
  end

  defp fetch_resource(opts) do
    case opts[:resource] do
      nil -> {:error, "#{inspect(__MODULE__)} requires a `:resource` option"}
      resource -> {:ok, resource}
    end
  end

  defp call_opts(opts) do
    [authorize?: Keyword.get(opts, :authorize_reads?, false)]
    |> maybe_put(:domain, opts[:domain])
    |> maybe_put(:tenant, opts[:tenant])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  ## Rules

  defp evaluate(record, flag, context) do
    cond do
      not truthy?(Map.get(record, :enabled)) -> false
      not tenant_allowed?(record, context) -> false
      allowed_role?(record, context) -> true
      true -> within_rollout?(record, flag, context)
    end
  end

  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp tenant_allowed?(record, context) do
    case Map.get(record, :allowed_tenants) do
      nil -> true
      [] -> true
      tenants -> to_string_or_nil(context.tenant) in Enum.map(tenants, &to_string/1)
    end
  end

  defp allowed_role?(record, context) do
    case Map.get(record, :allowed_roles) do
      nil -> false
      [] -> false
      roles -> Context.has_any_role?(context, roles)
    end
  end

  defp within_rollout?(record, flag, context) do
    case Map.get(record, :rollout_percentage) do
      nil -> true
      percentage when percentage >= 100 -> true
      percentage when percentage <= 0 -> false
      percentage -> bucket(flag, context) < percentage
    end
  end

  # Salted with the flag key so that two flags at 10% do not select the same
  # users, and stable per actor so nobody sees the feature flicker.
  defp bucket(flag, context) do
    :erlang.phash2({Flag.key(flag), context.targeting_key || "anonymous"}, 100)
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value), do: to_string(value)
end
