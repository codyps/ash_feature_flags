defmodule AshFeatureFlags.Provider.LaunchDarkly do
  @moduledoc """
  Evaluates flags with LaunchDarkly.

  LaunchDarkly ships an Erlang/Elixir server SDK
  ([`launchdarkly_server_sdk`](https://hex.pm/packages/launchdarkly_server_sdk),
  module `:ldclient`), which evaluates flags locally against a streamed
  ruleset — no HTTP call per check. This provider drives it.

      # mix.exs
      {:launchdarkly_server_sdk, "~> 3.0"}

      # application start, before your supervisor
      :ldclient.start_instance(System.fetch_env!("LAUNCHDARKLY_SDK_KEY"))

      # config
      config :ash_feature_flags,
        provider: AshFeatureFlags.Provider.LaunchDarkly

  ## Options

    * `:instance` — the LaunchDarkly instance tag, defaults to `:default`.
      Use this to point staging and production resources at different
      environments in the same node.
    * `:kind` — the LDContext kind, defaults to `"user"`
    * `:client` — override the module called; anything exporting
      `variation/4` works, which is the seam for tests

  ## How the context maps

  The actor becomes an LDContext:

      %{
        kind: "user",
        key: "user?id=8e...",     # ash_authentication subject
        roles: ["admin"],          # from `role_keys`
        tenant: "acme",
        resource: "MyApp.Shop.Order",
        action: "checkout",
        ...public actor attributes and any `context` you passed
      }

  So LaunchDarkly targeting rules can be written against roles and tenants
  directly, and percentage rollouts stay stable per user because the key is the
  same subject `ash_authentication` uses.

  ## Anonymous actors

  With no actor there is no key, so the context is marked `anonymous: true`
  with a constant key. LaunchDarkly excludes anonymous contexts from its user
  dashboard, which is what you want for logged-out traffic.
  """

  @behaviour AshFeatureFlags.Provider

  alias AshFeatureFlags.{Context, Flag}

  @impl AshFeatureFlags.Provider
  def enabled?(%Flag{} = flag, %Context{} = context, opts) do
    case variation(flag, context, flag.default, opts) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, value} when is_binary(value) -> {:ok, value not in ["", "off", "false"]}
      {:ok, other} -> {:error, {:unexpected_value, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl AshFeatureFlags.Provider
  def variant(%Flag{} = flag, %Context{} = context, opts) do
    case variation(flag, context, nil, opts) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, value} -> {:ok, to_string(value)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp variation(flag, context, default, opts) do
    client = opts[:client] || :ldclient
    instance = opts[:instance] || :default

    cond do
      not Code.ensure_loaded?(client) ->
        {:error,
         """
         #{inspect(__MODULE__)} needs the LaunchDarkly Erlang SDK.

         Add `{:launchdarkly_server_sdk, "~> 3.0"}` to your deps and call
         `:ldclient.start_instance(sdk_key)` at application start, or pass a
         `client:` module that exports `variation/4`.
         """}

      not function_exported?(client, :variation, 4) ->
        {:error, "#{inspect(client)} does not export variation/4"}

      true ->
        {:ok,
         client.variation(Flag.key(flag), ld_context(flag, context, opts), default, instance)}
    end
  rescue
    exception -> {:error, exception}
  end

  defp ld_context(flag, %Context{} = context, opts) do
    base = %{
      kind: to_string(opts[:kind] || "user"),
      key: context.targeting_key || "anonymous"
    }

    base =
      if context.targeting_key, do: base, else: Map.put(base, :anonymous, true)

    attributes =
      context.attributes
      |> Map.merge(flag.context)
      |> Map.merge(context.extra)
      |> Map.merge(%{
        roles: Enum.map(context.roles, &to_string/1),
        tenant: stringify(context.tenant),
        resource: stringify(context.resource),
        action: stringify(context.action)
      })
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(fn {key, value} -> {to_key(key), value} end)

    Map.merge(attributes, base)
  end

  # Attribute names from Ash are already atoms; anything arriving as a string
  # came from a caller-supplied `context:` map, which may ultimately be user
  # input. `String.to_atom/1` on that is an unbounded atom table, so string
  # keys stay strings unless the atom already exists.
  defp to_key(key) when is_atom(key), do: key

  defp to_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value

  defp stringify(value) when is_atom(value) do
    case Atom.to_string(value) do
      "Elixir." <> rest -> rest
      other -> other
    end
  end

  defp stringify(value), do: to_string(value)
end
