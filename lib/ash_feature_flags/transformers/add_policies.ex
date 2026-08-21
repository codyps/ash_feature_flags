defmodule AshFeatureFlags.Transformers.AddPolicies do
  @moduledoc """
  Compiles `guard_action` and `guard_attribute` declarations into
  `Ash.Policy.Authorizer` policies and field policies.

  ## Why policies rather than a change or a preparation

  Because policies are where `ash_authentication`'s roles and rules already
  live. Ash requires *every* applicable policy to pass, so emitting one veto
  policy per guard means a flag guard ANDs with whatever the resource already
  says about who may do what — no ordering rules to learn, and `Ash.can?/3`,
  `ash_graphql`, `ash_json_api` and AshAdmin all respect it for free.

  `guard_action [:publish], flag: :publishing_v2` becomes:

      policy action(:publish) do
        forbid_unless flag_enabled(:publishing_v2)
        authorize_if always()
      end

  The trailing `authorize_if always()` is what makes this a veto rather than a
  grant: the policy passes as soon as the flag is on, leaving the actual "may
  this actor do this?" decision to your own policies.

  `guard_attribute` becomes a field policy, plus a `field_policy :*` catch-all
  when the resource had no field policies of its own — Ash requires every
  public field to be covered once any field policy exists, and adding this
  extension should not silently hide unrelated columns.

  ## Resources that were not using the policy authorizer

  Adding `Ash.Policy.Authorizer` to a resource that did not have it makes Ash
  forbid anything no policy authorizes. To keep "add the extension" from
  locking down actions you never asked to guard, a catch-all `policy always()`
  is appended in that case. Opt out with `unguarded_actions :deny` once you are
  ready to write full policies.

  A resource that *already* declared the authorizer — even with no policies at
  all, which is Ash's deny-everything posture — never gets the catch-all.
  Adding this extension must not be able to open a resource that was closed.
  """

  use Spark.Dsl.Transformer

  alias AshFeatureFlags.{ActionGuard, AttributeGuard, Info}
  alias Spark.Dsl.Transformer

  # Ash's own field-policy bookkeeping (expanding `:*`, verifying coverage,
  # caching expressions) has to see the policies we add.
  def before?(Ash.Policy.Authorizer.Transformers.AddMissingFieldPolicies), do: true
  def before?(Ash.Policy.Authorizer.Transformers.CacheFieldPolicies), do: true
  def before?(_), do: false

  def after?(_), do: false

  def transform(dsl) do
    # Validate before building anything. Ash's own field-policy transformer
    # runs after ours and would reject a bad field reference first, with a
    # message about field policies the user never wrote — checking here means
    # they get told about the `guard_attribute` they did write.
    with :ok <- AshFeatureFlags.Verifiers.VerifyGuards.verify(dsl) do
      do_transform(dsl)
    end
  end

  defp do_transform(dsl) do
    # The catch-all exists to preserve what a resource did *before* the
    # extension. A resource that already declared `Ash.Policy.Authorizer` was
    # already authorizing — with zero policies that is Ash's deny-everything
    # posture, and quietly appending `authorize_if always()` would turn a
    # locked-down resource into an open one. So the question is whether the
    # user asked for authorization, not merely whether they wrote policies.
    already_authorized? =
      Ash.Policy.Authorizer in List.wrap(Transformer.get_persisted(dsl, :authorizers, [])) or
        Ash.Policy.Info.policies(dsl) != []

    had_field_policies? = Ash.Policy.Info.field_policies(dsl) != []

    {action_guards, attribute_guards} =
      if Info.policies?(dsl) do
        {Info.action_guards(dsl), Info.attribute_guards(dsl)}
      else
        {[], []}
      end

    with {:ok, dsl} <- add_action_policies(dsl, action_guards),
         {:ok, dsl} <- add_field_policies(dsl, attribute_guards, had_field_policies?),
         {:ok, dsl} <- add_filter_policies(dsl, attribute_guards),
         {:ok, dsl} <- allow_unguarded_actions(dsl, already_authorized?) do
      {:ok, ensure_authorizer(dsl)}
    end
  end

  ## Action guards -> policies

  defp add_action_policies(dsl, guards) do
    reduce_entities(dsl, guards, [:policies], &build_action_policy(dsl, &1))
  end

  defp build_action_policy(dsl, %ActionGuard{} = guard) do
    with {:ok, forbid_unless} <- check_entity(:forbid_unless, check_ref(guard)),
         {:ok, authorize_if} <-
           check_entity(:authorize_if, {Ash.Policy.Check.Static, result: true}) do
      build_policy(:policy,
        condition: [{Ash.Policy.Check.Action, action: guard.actions}],
        description: guard.description || describe_action_guard(guard),
        error_message: guard.message || default_message(dsl, guard),
        policies: [forbid_unless, authorize_if]
      )
    end
  end

  ## Attribute guards -> field policies

  defp add_field_policies(dsl, [], _had_field_policies?), do: {:ok, dsl}

  defp add_field_policies(dsl, guards, had_field_policies?) do
    with {:ok, dsl} <- reduce_entities(dsl, guards, [:field_policies], &build_field_policy/1) do
      if had_field_policies? do
        {:ok, dsl}
      else
        # Once any field policy exists, Ash demands coverage of every public,
        # non-primary-key field. Everything we were not asked to guard keeps
        # being visible.
        with {:ok, policy} <-
               build_field_policy_entity(
                 fields: [:*],
                 description: "fields not guarded by a feature flag",
                 policies: [
                   ok!(check_entity(:authorize_if, {Ash.Policy.Check.Static, result: true}))
                 ]
               ) do
          {:ok, Transformer.add_entity(dsl, [:field_policies], policy, type: :append)}
        end
      end
    end
  end

  defp build_field_policy(%AttributeGuard{} = guard) do
    with {:ok, authorize_if} <- check_entity(:authorize_if, check_ref(guard)) do
      build_field_policy_entity(
        fields: guard.attributes,
        description:
          guard.description ||
            "visible only while feature flag(s) #{inspect(guard.flag)} are enabled",
        policies: [authorize_if]
      )
    end
  end

  ## Closing the filter leak
  #
  # A field policy hides a value but does not stop a query from filtering on
  # it — `filter(salary > 100_000)` still narrows the result set, which leaks
  # the value a bisection at a time. Ash's own docs recommend pairing field
  # policies with a `filtering_on` check; `prevent_filtering?` does that for
  # you.

  defp add_filter_policies(dsl, guards) do
    guards
    |> Enum.filter(& &1.prevent_filtering?)
    |> then(&reduce_entities(dsl, &1, [:policies], fn guard -> build_filter_policy(guard) end))
  end

  defp build_filter_policy(%AttributeGuard{} = guard) do
    {_check_module, check_opts} = check_ref(guard)

    with {:ok, forbids} <- filtering_checks(guard.attributes),
         {:ok, authorize_if} <-
           check_entity(:authorize_if, {Ash.Policy.Check.Static, result: true}) do
      build_policy(:policy,
        # The policy only applies to reads where the flag is *off*; when the
        # flag is on it does not participate at all.
        condition: [
          {Ash.Policy.Check.ActionType, type: [:read]},
          {AshFeatureFlags.Checks.FlagDisabled, check_opts}
        ],
        description:
          "reads may not filter on #{inspect(guard.attributes)} while feature flag(s) #{inspect(guard.flag)} are off",
        error_message:
          "Cannot filter on #{Enum.map_join(guard.attributes, ", ", &inspect/1)}: hidden by a feature flag.",
        policies: forbids ++ [authorize_if]
      )
    end
  end

  defp filtering_checks(fields) do
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, acc} ->
      case check_entity(:forbid_if, {Ash.Policy.Check.FilteringOn, path: [], field: field}) do
        {:ok, entity} -> {:cont, {:ok, acc ++ [entity]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  ## Preserving pre-extension behaviour

  defp allow_unguarded_actions(dsl, true = _already_authorized?), do: {:ok, dsl}

  defp allow_unguarded_actions(dsl, false) do
    if Info.unguarded_actions(dsl) == :deny do
      {:ok, dsl}
    else
      with {:ok, authorize_if} <-
             check_entity(:authorize_if, {Ash.Policy.Check.Static, result: true}),
           {:ok, policy} <-
             build_policy(:policy,
               condition: [{Ash.Policy.Check.Static, result: true}],
               description: "actions with no feature flag guard (added by AshFeatureFlags)",
               policies: [authorize_if]
             ) do
        {:ok, Transformer.add_entity(dsl, [:policies], policy, type: :append)}
      end
    end
  end

  defp ensure_authorizer(dsl) do
    authorizers = List.wrap(Transformer.get_persisted(dsl, :authorizers, []))

    if Ash.Policy.Authorizer in authorizers do
      dsl
    else
      Transformer.persist(dsl, :authorizers, authorizers ++ [Ash.Policy.Authorizer])
    end
  end

  ## Building blocks

  defp check_ref(%ActionGuard{} = guard), do: do_check_ref(guard.flag, guard.match, guard.variant)

  defp check_ref(%AttributeGuard{} = guard),
    do: do_check_ref(guard.flag, guard.match, guard.variant)

  defp do_check_ref(flags, match, variant) do
    opts = [flag: flags, match: match]
    opts = if variant, do: Keyword.put(opts, :variant, variant), else: opts
    {AshFeatureFlags.Checks.FlagEnabled, opts}
  end

  defp check_entity(type, check) do
    Transformer.build_entity(Ash.Policy.Authorizer, [:policies, :policy], type, check: check)
  end

  defp build_policy(name, opts) do
    Transformer.build_entity(Ash.Policy.Authorizer, [:policies], name, opts)
  end

  defp build_field_policy_entity(opts) do
    Transformer.build_entity(Ash.Policy.Authorizer, [:field_policies], :field_policy, opts)
  end

  defp reduce_entities(dsl, entries, path, builder) do
    Enum.reduce_while(entries, {:ok, dsl}, fn entry, {:ok, dsl} ->
      case builder.(entry) do
        {:ok, entity} -> {:cont, {:ok, Transformer.add_entity(dsl, path, entity, type: :append)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp ok!({:ok, value}), do: value

  defp describe_action_guard(%ActionGuard{} = guard) do
    "#{Enum.map_join(guard.actions, ", ", &inspect/1)} guarded by feature flag(s) #{inspect(guard.flag)}"
  end

  defp default_message(dsl, %ActionGuard{} = guard) do
    resource = Transformer.get_persisted(dsl, :module)
    flags = Enum.map_join(guard.flag, ", ", &inspect/1)

    "This action on #{inspect(resource)} is behind feature flag(s) #{flags}, which are not enabled for you."
  end
end
