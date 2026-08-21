defmodule AshFeatureFlags.AshAuthenticationTest do
  use AshFeatureFlags.Case, async: false

  alias AshFeatureFlags.Context
  alias AshFeatureFlags.Test.AuthUser

  defp auth_user(attrs \\ []) do
    struct(AuthUser, Keyword.merge([id: Ash.UUID.generate(), role: :editor], attrs))
  end

  describe "targeting key" do
    test "uses the ash_authentication subject when the actor is a user resource" do
      user = auth_user()
      context = Context.build(actor: user)

      assert context.subject == "user?id=#{user.id}"
      assert context.targeting_key == context.subject
    end

    test "is the same string ash_authentication puts in tokens and sessions" do
      # This is the whole point: a percentage rollout keyed on the subject
      # picks the same users your session layer already identifies.
      user = auth_user()

      assert Context.build(actor: user).targeting_key == AshAuthentication.user_to_subject(user)
    end

    test "falls back to the primary key for plain Ash resources" do
      user = actor()
      context = Context.build(actor: user)

      assert context.subject == nil
      assert context.targeting_key =~ user.id
    end

    test "a nil actor has no targeting key" do
      assert Context.build([]).targeting_key == nil
    end
  end

  describe "roles" do
    test "are read off the user resource without any configuration" do
      assert Context.build(actor: auth_user(role: :admin)).roles == [:admin]
    end

    test "can be pointed at a different attribute" do
      Application.put_env(:ash_feature_flags, :role_keys, [:email])
      on_exit(fn -> Application.delete_env(:ash_feature_flags, :role_keys) end)

      context = Context.build(actor: auth_user(email: "someone@example.com"))
      assert "someone@example.com" in context.roles
    end
  end

  describe "policies combining roles and flags" do
    test "an ash_authentication user is gated by both role and flag" do
      set_flag("publishing-v2", true)

      assert {:ok, _} = Ash.create(Post, %{title: "x"}, actor: auth_user(role: :editor))
      assert {:error, _} = Ash.create(Post, %{title: "x"}, actor: auth_user(role: :customer))

      set_flag("publishing-v2", false)
      assert {:error, _} = Ash.create(Post, %{title: "x"}, actor: auth_user(role: :editor))
    end
  end

  describe "subject-keyed rollouts" do
    test "a user stays in the same bucket across evaluations" do
      set_flag("bucketed", fn context ->
        :erlang.phash2(context.targeting_key, 100) < 50
      end)

      user = auth_user()

      results = for _ <- 1..10, do: AshFeatureFlags.enabled?(:bucketed, actor: user)

      assert length(Enum.uniq(results)) == 1
    end
  end
end
