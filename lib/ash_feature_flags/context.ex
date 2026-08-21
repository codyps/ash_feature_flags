defmodule AshFeatureFlags.Context do
  @moduledoc """
  The evaluation context handed to a provider.

  This is the bridge between Ash/`ash_authentication` and whatever targeting
  model your flag backend speaks. It carries the actor, a stable targeting key,
  the actor's roles, the tenant, and the resource/action being authorized.

  Providers translate it:

    * `AshFeatureFlags.Provider.Flipt` sends `entity_id` + a string `context` map
    * `AshFeatureFlags.Provider.OpenFeature` sends an OFREP evaluation context
      with `targetingKey`
    * `AshFeatureFlags.Provider.LaunchDarkly` sends an LDContext of kind `user`

  ## Roles

  `ash_authentication` deliberately has no opinion about roles — they live on
  your user resource. So we look for them, in order, on the attributes named by:

      config :ash_feature_flags, role_keys: [:role, :roles]

  Both a single value (`role: :admin`) and a list (`roles: [:admin, :billing]`)
  are understood, and values are normalized to atoms where possible so that
  `enabled_for_roles [:admin]` matches a `"admin"` string from the database.
  """

  alias AshFeatureFlags.Info

  defstruct [
    :actor,
    :targeting_key,
    :subject,
    :tenant,
    :resource,
    :action,
    :action_type,
    :domain,
    :changeset,
    :query,
    roles: [],
    attributes: %{},
    extra: %{}
  ]

  @type t :: %__MODULE__{
          actor: term(),
          targeting_key: String.t() | nil,
          subject: String.t() | nil,
          tenant: term(),
          resource: module() | nil,
          action: atom() | nil,
          action_type: atom() | nil,
          domain: module() | nil,
          changeset: Ash.Changeset.t() | nil,
          query: Ash.Query.t() | nil,
          roles: [atom() | String.t()],
          attributes: map(),
          extra: map()
        }

  @default_role_keys [:role, :roles]

  @doc """
  Builds a context from an `Ash.Policy.Authorizer` struct.

  This is what the policy checks use, so everything a check can see — actor,
  tenant, resource, action, and the changeset/query in flight — is available
  for targeting.
  """
  @spec from_authorizer(term(), map() | nil) :: t()
  def from_authorizer(actor, authorizer) do
    subject = authorizer && Map.get(authorizer, :subject)

    %__MODULE__{
      resource: authorizer && Map.get(authorizer, :resource),
      action: action_name(authorizer),
      action_type: action_type(authorizer),
      domain: authorizer && Map.get(authorizer, :domain),
      tenant: subject && Map.get(subject, :tenant),
      changeset: subject_of(subject, Ash.Changeset),
      query: subject_of(subject, Ash.Query)
    }
    |> put_actor(actor)
  end

  @doc """
  Builds a context for a manual `AshFeatureFlags.enabled?/2` call.

  ## Options

    * `:actor` - the actor to evaluate for, usually the current user
    * `:tenant` - the tenant, defaulting to the actor's tenant if it has one
    * `:resource`, `:action`, `:domain` - optional, used for targeting rules
    * `:roles` - override the roles inferred from the actor
    * `:context` - extra key/values passed straight through to the provider
  """
  @spec build(keyword()) :: t()
  def build(opts) when is_list(opts) do
    %__MODULE__{
      tenant: opts[:tenant],
      resource: opts[:resource],
      action: opts[:action],
      action_type: opts[:action_type],
      domain: opts[:domain],
      extra: Map.new(opts[:context] || %{})
    }
    |> put_actor(opts[:actor])
    |> then(fn context ->
      case opts[:roles] do
        nil -> context
        roles -> %{context | roles: normalize_roles(roles)}
      end
    end)
  end

  @doc """
  Attaches an actor, deriving its targeting key, roles and attributes.
  """
  @spec put_actor(t(), term()) :: t()
  def put_actor(%__MODULE__{} = context, nil), do: context

  def put_actor(%__MODULE__{} = context, actor) do
    %{
      context
      | actor: actor,
        roles: roles_for(actor),
        subject: subject_for(actor),
        targeting_key: targeting_key_for(actor),
        attributes: actor_attributes(actor),
        tenant: context.tenant || tenant_for(actor)
    }
  end

  @doc """
  True if the actor holds any of the given roles.

  Comparison is done on normalized values, so `:admin`, `"admin"` and
  `"Admin"` all match a declared `[:admin]`.
  """
  @spec has_any_role?(t(), [atom() | String.t()]) :: boolean()
  def has_any_role?(_context, []), do: false

  def has_any_role?(%__MODULE__{roles: roles}, candidates) do
    candidates = MapSet.new(normalize_roles(candidates))
    Enum.any?(roles, &MapSet.member?(candidates, &1))
  end

  @doc """
  The context rendered as a flat map of strings, which is what Flipt and OFREP
  style backends expect for their segment/targeting rules.
  """
  @spec to_string_map(t()) :: %{optional(String.t()) => String.t()}
  def to_string_map(%__MODULE__{} = context) do
    base = %{
      "roles" => context.roles |> Enum.map_join(",", &to_string/1),
      "tenant" => stringify(context.tenant),
      "resource" => stringify(context.resource),
      "action" => stringify(context.action),
      "action_type" => stringify(context.action_type),
      "subject" => stringify(context.subject)
    }

    context.attributes
    |> Map.merge(context.extra)
    |> Enum.reduce(base, fn {key, value}, acc ->
      Map.put(acc, to_string(key), stringify(value))
    end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  A stable cache key for this context under a given flag and provider.

  Everything that can change the answer has to be in here, and the rule of
  thumb is simple: if it is sent to the provider, it belongs in the key.
  `to_string_map/1` is exactly what the HTTP providers transmit — roles,
  tenant, resource, action, public actor attributes, extra context — so it is
  the basis, plus the targeting key that drives percentage rollouts.

  The provider's *options* count too: the same module pointed at two Flipt
  namespaces or two LaunchDarkly environments is two different backends and
  must not share entries.

  The flag's `variant` is part of the key because a variant flag caches the
  *comparison result*, not the variant — without it, `flag_enabled(:exp,
  variant: "treatment")` and `flag_enabled(:exp, variant: "control")` would
  collide and one cohort would be handed the other's answer.

  The shape is `{provider_ref_hash, flag_key, context_hash}` — `flag_key` stays
  literal so `AshFeatureFlags.Cache.clear/1` can match on it.
  """
  @spec cache_key(t(), AshFeatureFlags.Flag.t(), module() | {module(), keyword()}) :: term()
  def cache_key(%__MODULE__{} = context, flag, provider) do
    {:erlang.phash2(provider), AshFeatureFlags.Flag.key(flag),
     :erlang.phash2({
       flag.variant,
       flag.context,
       context.targeting_key,
       to_string_map(context)
     })}
  end

  # `nil` rather than `false` when the subject is the other kind, so that
  # providers pattern matching on `%Ash.Query{}` / `nil` behave.
  defp subject_of(%module{} = subject, module), do: subject
  defp subject_of(_subject, _module), do: nil

  defp action_name(nil), do: nil

  defp action_name(authorizer) do
    case Map.get(authorizer, :action) do
      %{name: name} -> name
      name when is_atom(name) -> name
      _ -> nil
    end
  end

  defp action_type(nil), do: nil

  defp action_type(authorizer) do
    case Map.get(authorizer, :action) do
      %{type: type} -> type
      _ -> nil
    end
  end

  ## Actor introspection

  defp roles_for(actor) do
    role_keys()
    |> Enum.flat_map(fn key ->
      case fetch_actor_field(actor, key) do
        {:ok, value} -> List.wrap(value)
        :error -> []
      end
    end)
    |> normalize_roles()
  end

  defp role_keys do
    Application.get_env(:ash_feature_flags, :role_keys, @default_role_keys)
  end

  @doc false
  def normalize_roles(roles) do
    roles
    |> List.wrap()
    |> Enum.flat_map(fn
      nil -> []
      role when is_atom(role) -> [role]
      role when is_binary(role) -> [normalize_role_string(role)]
      %{name: name} -> [normalize_role_string(to_string(name))]
      other -> [other]
    end)
    |> Enum.uniq()
  end

  defp normalize_role_string(role) do
    downcased = String.downcase(role)

    try do
      String.to_existing_atom(downcased)
    rescue
      ArgumentError -> downcased
    end
  end

  defp fetch_actor_field(%_{} = actor, key) do
    case Map.fetch(actor, key) do
      {:ok, %Ash.NotLoaded{}} -> :error
      {:ok, %Ash.ForbiddenField{}} -> :error
      {:ok, nil} -> :error
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp fetch_actor_field(actor, key) when is_map(actor) do
    with :error <- Map.fetch(actor, key) do
      Map.fetch(actor, to_string(key))
    end
  end

  defp fetch_actor_field(_actor, _key), do: :error

  defp tenant_for(actor) do
    case fetch_actor_field(actor, :tenant) do
      {:ok, tenant} -> tenant
      :error -> nil
    end
  end

  # `ash_authentication` gives us a stable subject string ("user?id=...") which
  # is exactly the kind of identifier flag backends want for percentage
  # rollouts. Fall back to the primary key when it isn't available.
  defp subject_for(actor), do: AshFeatureFlags.AshAuthentication.subject(actor)

  defp targeting_key_for(actor) do
    case subject_for(actor) do
      nil -> fallback_targeting_key(actor)
      subject -> subject
    end
  end

  defp fallback_targeting_key(%struct{} = actor) do
    cond do
      Ash.Resource.Info.resource?(struct) ->
        pkey = Ash.Resource.Info.primary_key(struct)

        values =
          pkey
          |> Enum.map(&stringify(Map.get(actor, &1)))
          |> Enum.reject(&is_nil/1)

        if values == [], do: nil, else: Enum.join([inspect(struct) | values], ":")

      true ->
        stringify(Map.get(actor, :id))
    end
  rescue
    _ -> nil
  end

  defp fallback_targeting_key(actor) when is_map(actor) do
    stringify(Map.get(actor, :id) || Map.get(actor, "id"))
  end

  defp fallback_targeting_key(_actor), do: nil

  # Only public, loaded, simple values are exposed for targeting. Sending an
  # entire user struct to a third party would be a nasty surprise.
  defp actor_attributes(%struct{} = actor) do
    if Ash.Resource.Info.resource?(struct) do
      struct
      |> Ash.Resource.Info.public_attributes()
      |> Enum.reduce(%{}, fn attribute, acc ->
        case Map.get(actor, attribute.name) do
          %Ash.NotLoaded{} ->
            acc

          %Ash.ForbiddenField{} ->
            acc

          nil ->
            acc

          value when is_binary(value) or is_atom(value) or is_number(value) ->
            Map.put(acc, attribute.name, value)

          _other ->
            acc
        end
      end)
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp actor_attributes(_actor), do: %{}

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: inspect_atom(value)
  defp stringify(value) when is_number(value), do: to_string(value)

  defp stringify(value) do
    if String.Chars.impl_for(value), do: to_string(value), else: inspect(value)
  end

  defp inspect_atom(value) do
    case Atom.to_string(value) do
      "Elixir." <> rest -> rest
      other -> other
    end
  end

  @doc false
  def flag_definition(resource, name) when is_atom(resource) and not is_nil(resource) do
    Info.flag(resource, name)
  end

  def flag_definition(_resource, _name), do: :error
end
