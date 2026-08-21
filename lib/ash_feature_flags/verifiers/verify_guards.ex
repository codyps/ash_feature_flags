defmodule AshFeatureFlags.Verifiers.VerifyGuards do
  @moduledoc """
  Compile-time checks so flag mistakes surface at `mix compile`, not at 3am.

  Verifies that:

    * every flag referenced by a guard is declared in the same section
    * every guarded action exists on the resource
    * every guarded field exists, is public, and is not part of the primary key
      (Ash always allows reading primary keys, so guarding one would be a lie)
    * every statically declared provider accepts its options, by asking the
      provider itself through `c:AshFeatureFlags.Provider.init/1`
  """

  use Spark.Dsl.Verifier

  alias AshFeatureFlags.{ActionGuard, AttributeGuard, Info}
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)
    declared = MapSet.new(Info.flags(dsl), & &1.name)

    with :ok <- verify_action_guards(dsl, module, declared),
         :ok <- verify_attribute_guards(dsl, module, declared),
         :ok <- verify_providers(dsl, module) do
      :ok
    end
  end

  # A provider that needs a `:base_url` should say so at `mix compile`, not on
  # the first request in production. Only providers declared in the DSL can be
  # checked; ones coming from application config are resolved at runtime.
  defp verify_providers(dsl, module) do
    [{nil, Info.provider(dsl)} | Enum.map(Info.flags(dsl), &{&1.name, &1.provider})]
    |> Enum.reject(fn {_flag, provider} -> is_nil(provider) end)
    |> Enum.reduce_while(:ok, fn {flag, provider}, :ok ->
      {provider_module, opts} = AshFeatureFlags.Provider.split(provider)

      cond do
        not Code.ensure_loaded?(provider_module) ->
          {:cont, :ok}

        not function_exported?(provider_module, :init, 1) ->
          {:cont, :ok}

        true ->
          case provider_module.init(opts) do
            {:ok, _opts} ->
              {:cont, :ok}

            {:error, reason} ->
              {:halt,
               {:error,
                DslError.exception(
                  module: module,
                  path: [:feature_flags, :provider],
                  message:
                    "Invalid provider configuration#{flag && " for flag #{inspect(flag)}"}: " <>
                      to_message(reason)
                )}}
          end
      end
    end)
  end

  defp to_message(reason) when is_binary(reason), do: reason
  defp to_message(reason), do: inspect(reason)

  defp verify_action_guards(dsl, module, declared) do
    Enum.reduce_while(Info.action_guards(dsl), :ok, fn %ActionGuard{} = guard, :ok ->
      with :ok <- verify_flags_declared(module, guard.flag, declared, :guard_action),
           :ok <- verify_actions_exist(dsl, module, guard) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp verify_attribute_guards(dsl, module, declared) do
    Enum.reduce_while(Info.attribute_guards(dsl), :ok, fn %AttributeGuard{} = guard, :ok ->
      with :ok <- verify_flags_declared(module, guard.flag, declared, :guard_attribute),
           :ok <- verify_fields_guardable(dsl, module, guard) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp verify_flags_declared(module, flags, declared, entity) do
    case Enum.reject(flags, &MapSet.member?(declared, &1)) do
      [] ->
        :ok

      missing ->
        {:error,
         DslError.exception(
           module: module,
           path: [:feature_flags, entity],
           message: """
           Undeclared feature flag(s): #{inspect(missing)}

           Declare each flag in the same `feature_flags` section before guarding with it:

               feature_flags do
                 flag #{inspect(hd(missing))}

                 #{entity} ..., flag: #{inspect(hd(missing))}
               end
           """
         )}
    end
  end

  defp verify_actions_exist(dsl, module, %ActionGuard{} = guard) do
    known = Enum.map(Ash.Resource.Info.actions(dsl), & &1.name)

    case Enum.reject(guard.actions, &(&1 in known)) do
      [] ->
        :ok

      missing ->
        {:error,
         DslError.exception(
           module: module,
           path: [:feature_flags, :guard_action],
           message: """
           Cannot guard action(s) that do not exist: #{inspect(missing)}

           Known actions: #{inspect(known)}
           """
         )}
    end
  end

  defp verify_fields_guardable(dsl, module, %AttributeGuard{} = guard) do
    fields = Ash.Resource.Info.fields(dsl, [:attributes, :calculations, :aggregates])
    by_name = Map.new(fields, &{&1.name, &1})
    primary_key = Ash.Resource.Info.primary_key(dsl)

    Enum.reduce_while(guard.attributes, :ok, fn name, :ok ->
      cond do
        not Map.has_key?(by_name, name) ->
          {:halt,
           {:error,
            DslError.exception(
              module: module,
              path: [:feature_flags, :guard_attribute],
              message: """
              Cannot guard #{inspect(name)}: no such attribute, calculation or aggregate.
              """
            )}}

        name in primary_key ->
          {:halt,
           {:error,
            DslError.exception(
              module: module,
              path: [:feature_flags, :guard_attribute],
              message: """
              Cannot guard #{inspect(name)}: it is part of the primary key.

              Ash field policies always permit reading primary keys, so a guard
              here would never take effect. Guard the actions that expose the
              record instead:

                  guard_action [:read], flag: #{inspect(hd(guard.flag))}
              """
            )}}

        not Map.get(by_name[name], :public?, true) ->
          {:halt,
           {:error,
            DslError.exception(
              module: module,
              path: [:feature_flags, :guard_attribute],
              message: """
              Cannot guard #{inspect(name)}: it is private.

              Private fields are already hidden from external interfaces. Field
              policies only apply to them when
              `config :ash, policies: [private_fields: :include]` is set; make
              the field public, or use that setting if you meant it.
              """
            )}}

        true ->
          {:cont, :ok}
      end
    end)
  end
end
