defmodule AshFeatureFlags.RuntimeApiTest do
  use AshFeatureFlags.Case, async: false

  alias AshFeatureFlags.Context

  describe "enabled?/2" do
    test "reads a flag with no resource context at all" do
      set_flag("standalone", true)
      assert AshFeatureFlags.enabled?(:standalone)

      set_flag("standalone", false)
      refute AshFeatureFlags.enabled?(:standalone)
    end

    test "an unknown flag is off, not an error" do
      refute AshFeatureFlags.enabled?(:never_heard_of_it)
    end

    test "honours a resource's flag declaration" do
      # `:publishing_v2` is declared on Post with `enabled_for_roles [:admin]`.
      set_flag("publishing-v2", false)

      assert AshFeatureFlags.enabled?(:publishing_v2,
               resource: Post,
               actor: actor(role: :admin)
             )

      refute AshFeatureFlags.enabled?(:publishing_v2,
               resource: Post,
               actor: actor(role: :editor)
             )
    end

    test "roles can be passed directly, without an actor" do
      set_flag("publishing-v2", false)

      assert AshFeatureFlags.enabled?(:publishing_v2, resource: Post, roles: [:admin])
      refute AshFeatureFlags.enabled?(:publishing_v2, resource: Post, roles: [:editor])
    end

    test "extra context reaches the provider" do
      set_flag("regional", fn context -> context.extra[:country] == "NZ" end)

      assert AshFeatureFlags.enabled?(:regional, context: %{country: "NZ"})
      refute AshFeatureFlags.enabled?(:regional, context: %{country: "AU"})
    end
  end

  describe "all_enabled?/2" do
    setup do
      set_flag("a", true)
      set_flag("b", false)
      :ok
    end

    test "defaults to requiring all of them" do
      refute AshFeatureFlags.all_enabled?([:a, :b])
      assert AshFeatureFlags.all_enabled?([:a])
    end

    test "match: :any requires only one" do
      assert AshFeatureFlags.all_enabled?([:a, :b], match: :any)
      refute AshFeatureFlags.all_enabled?([:b], match: :any)
    end
  end

  describe "with_flag/4" do
    test "picks the branch" do
      set_flag("new-path", true)
      assert AshFeatureFlags.with_flag(:new_path, [], fn -> :new end, fn -> :old end) == :new

      set_flag("new-path", false)
      assert AshFeatureFlags.with_flag(:new_path, [], fn -> :new end, fn -> :old end) == :old
    end
  end

  describe "variants" do
    test "reads a variant string" do
      set_flag("experiment", "treatment")

      assert {:ok, "treatment"} = AshFeatureFlags.variant(:experiment)
    end

    test "a variant counts as enabled" do
      set_flag("experiment", "treatment")
      assert AshFeatureFlags.enabled?(:experiment)
    end
  end

  describe "context building" do
    test "derives roles from both :role and :roles" do
      context = Context.build(actor: actor(role: :editor, roles: ["billing"]))

      assert :editor in context.roles
      assert :billing in context.roles
    end

    test "normalizes string roles to atoms so declarations match" do
      context = Context.build(actor: actor(roles: ["Admin"]))
      assert :admin in context.roles
    end

    test "an unknown role string stays a string rather than creating an atom" do
      context = Context.build(actor: actor(roles: ["definitely_not_an_existing_atom_9f3a"]))
      assert "definitely_not_an_existing_atom_9f3a" in context.roles
    end

    test "the targeting key is stable for the same actor" do
      user = actor(role: :editor)

      assert Context.build(actor: user).targeting_key ==
               Context.build(actor: user).targeting_key

      refute Context.build(actor: user).targeting_key ==
               Context.build(actor: actor(role: :editor)).targeting_key
    end

    test "only simple public attributes are exposed to providers" do
      context = Context.build(actor: actor(role: :editor, email: "a@b.c"))
      strings = Context.to_string_map(context)

      assert strings["email"] == "a@b.c"
      assert strings["role"] == "editor"
      assert strings["roles"] == "editor"
    end

    test "tenant comes from the actor when not given explicitly" do
      assert Context.build(actor: actor(tenant: "acme")).tenant == "acme"
      assert Context.build(actor: actor(tenant: "acme"), tenant: "other").tenant == "other"
    end
  end

  describe "invalidate/1" do
    test "clears cached values" do
      # The cache is disabled in tests, so this only asserts the call is safe
      # and returns :ok in both shapes.
      assert :ok = AshFeatureFlags.invalidate()
      assert :ok = AshFeatureFlags.invalidate("some-flag")
    end
  end
end
