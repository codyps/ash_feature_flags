defmodule AshFeatureFlags.VariantsAndRolesTest do
  use AshFeatureFlags.Case, async: false

  alias AshFeatureFlags.{Cache, Context, Evaluator, Flag}

  describe "disabled_for_roles" do
    test "beats both the provider and enabled_for_roles" do
      flag = %Flag{
        name: :thing,
        enabled_for_roles: [:admin],
        disabled_for_roles: [:contractor]
      }

      set_flag("thing", true)

      assert Evaluator.enabled?(flag, Context.build(actor: actor(role: :admin)))
      assert Evaluator.enabled?(flag, Context.build(actor: actor(role: :editor)))

      # A denied role is off even though the provider says on *and* the actor
      # also holds an enabled role.
      refute Evaluator.enabled?(flag, Context.build(roles: [:contractor]))
      refute Evaluator.enabled?(flag, Context.build(roles: [:admin, :contractor]))
    end
  end

  describe "variant flags" do
    test "a flag with a declared variant is on only for that variant" do
      flag = %Flag{name: :experiment, variant: "treatment"}

      set_flag("experiment", "treatment")
      assert Evaluator.enabled?(flag, Context.build([]))

      set_flag("experiment", "control")
      refute Evaluator.enabled?(flag, Context.build([]))
    end

    test "variant?/4 compares against the provider's variant" do
      set_flag("experiment", "treatment")
      context = Context.build([])

      assert Evaluator.variant?(:experiment, context, "treatment")
      refute Evaluator.variant?(:experiment, context, "control")
    end

    test "asking a provider that cannot do variants is an error, not a crash" do
      defmodule BooleanOnlyProvider do
        @behaviour AshFeatureFlags.Provider
        @impl true
        def enabled?(_flag, _context, _opts), do: {:ok, true}
      end

      assert {:error, message} =
               Evaluator.variant(:experiment, Context.build([]), provider: BooleanOnlyProvider)

      assert message =~ "does not implement variant/3"
    end
  end

  describe "cache invalidation covers variants" do
    test "invalidate/1 drops the variant entry too" do
      Cache.clear()
      set_flag("experiment", "control")

      opts = [ttl: 60_000]
      context = Context.build([])

      assert {:ok, "control"} = Evaluator.variant(:experiment, context, opts)

      # `put/2` invalidates the key; without dropping the variant-shaped cache
      # entry we would keep serving "control" forever.
      set_flag("experiment", "treatment")

      assert {:ok, "treatment"} = Evaluator.variant(:experiment, context, opts)
    end
  end

  describe "match: :any" do
    test "one flag being on is enough" do
      set_flag("a", true)
      set_flag("b", false)

      assert Evaluator.all?([:a, :b], Context.build([]), :any)
      refute Evaluator.all?([:a, :b], Context.build([]), :all)
    end
  end

  describe "guards with several flags" do
    test "match: :all requires every flag" do
      # Post declares `guard_action [:publish], flag: :publishing_v2`; this
      # exercises the multi-flag path through the check directly.
      set_flag("a", true)
      set_flag("b", true)

      assert AshFeatureFlags.Checks.FlagEnabled.check(
               Context.build([]),
               flag: [:a, :b],
               match: :all
             )

      set_flag("b", false)

      refute AshFeatureFlags.Checks.FlagEnabled.check(
               Context.build([]),
               flag: [:a, :b],
               match: :all
             )

      assert AshFeatureFlags.Checks.FlagEnabled.check(
               Context.build([]),
               flag: [:a, :b],
               match: :any
             )
    end
  end

  describe "check descriptions" do
    test "read well in policy breakdowns" do
      assert AshFeatureFlags.Checks.FlagEnabled.describe(flag: :new_checkout) ==
               "feature flag :new_checkout is enabled"

      assert AshFeatureFlags.Checks.FlagEnabled.describe(flag: [:a, :b], match: :any) ==
               "feature flags [:a, :b] are any of them enabled"

      assert AshFeatureFlags.Checks.FlagEnabled.describe(flag: :x, variant: "t") ==
               "feature flag :x is set to variant \"t\""

      assert AshFeatureFlags.Checks.FlagDisabled.describe(flag: :x) ==
               "not feature flag :x is enabled"
    end
  end
end
