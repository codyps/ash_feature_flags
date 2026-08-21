defmodule AshFeatureFlags.Provider.LaunchDarklyTest do
  use AshFeatureFlags.Case, async: false

  alias AshFeatureFlags.{Context, Flag}
  alias AshFeatureFlags.Provider.LaunchDarkly

  defmodule FakeLDClient do
    @moduledoc "Mimics `:ldclient.variation/4`."

    def variation(key, context, default, instance) do
      send(self(), {:variation, key, context, default, instance})

      case Process.get(:ld_value, :unset) do
        :unset -> default
        value -> value
      end
    end
  end

  @opts [client: FakeLDClient]

  defp flag(attrs \\ []), do: struct(Flag, Keyword.merge([name: :new_checkout], attrs))
  defp context, do: Context.build(actor: actor(role: :editor, tenant: "acme"), resource: Post)

  describe "enabled?/3" do
    test "returns the SDK's boolean" do
      Process.put(:ld_value, true)
      assert {:ok, true} = LaunchDarkly.enabled?(flag(), context(), @opts)

      Process.put(:ld_value, false)
      assert {:ok, false} = LaunchDarkly.enabled?(flag(), context(), @opts)
    end

    test "passes the flag's default as the SDK default" do
      Process.delete(:ld_value)

      assert {:ok, true} = LaunchDarkly.enabled?(flag(default: true), context(), @opts)
      assert_received {:variation, "new-checkout", _context, true, :default}
    end

    test "builds an LDContext of kind user with a stable key" do
      Process.put(:ld_value, true)
      LaunchDarkly.enabled?(flag(), context(), @opts)

      assert_received {:variation, _key, ld_context, _default, _instance}

      assert ld_context.kind == "user"
      assert is_binary(ld_context.key)
      assert ld_context.roles == ["editor"]
      assert ld_context.tenant == "acme"
      assert ld_context.resource == "AshFeatureFlags.Test.Post"
    end

    test "anonymous actors are marked as such" do
      Process.put(:ld_value, true)
      LaunchDarkly.enabled?(flag(), Context.build([]), @opts)

      assert_received {:variation, _key, ld_context, _default, _instance}

      assert ld_context.key == "anonymous"
      assert ld_context.anonymous == true
    end

    test "the instance tag selects the environment" do
      Process.put(:ld_value, true)
      LaunchDarkly.enabled?(flag(), context(), client: FakeLDClient, instance: :staging)

      assert_received {:variation, _key, _context, _default, :staging}
    end

    test "a string value is treated as on" do
      Process.put(:ld_value, "treatment")
      assert {:ok, true} = LaunchDarkly.enabled?(flag(), context(), @opts)

      Process.put(:ld_value, "off")
      assert {:ok, false} = LaunchDarkly.enabled?(flag(), context(), @opts)
    end

    test "a missing SDK is reported with installation instructions" do
      assert {:error, message} =
               LaunchDarkly.enabled?(flag(), context(), client: NotARealModule)

      assert message =~ "launchdarkly_server_sdk"
    end
  end

  describe "variant/3" do
    test "returns the variation string" do
      Process.put(:ld_value, "treatment")
      assert {:ok, "treatment"} = LaunchDarkly.variant(flag(), context(), @opts)
    end

    test "nil means no variation" do
      Process.put(:ld_value, nil)
      assert {:ok, nil} = LaunchDarkly.variant(flag(), context(), @opts)
    end
  end
end
