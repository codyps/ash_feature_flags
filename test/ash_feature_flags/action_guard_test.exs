defmodule AshFeatureFlags.ActionGuardTest do
  use AshFeatureFlags.Case, async: false

  describe "guard_action" do
    test "forbids the action while the flag is off" do
      set_flag("publishing-v2", false)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(Post, %{title: "Draft"}, actor: actor(role: :editor))
    end

    test "allows the action once the flag is on" do
      set_flag("publishing-v2", true)

      assert {:ok, %Post{title: "Draft"}} =
               Ash.create(Post, %{title: "Draft"}, actor: actor(role: :editor))
    end

    test "leaves unguarded actions alone" do
      set_flag("publishing-v2", true)
      {:ok, post} = Ash.create(Post, %{title: "Draft"}, actor: actor(role: :editor))

      set_flag("publishing-v2", false)

      # :read carries no guard, so turning the flag off must not affect it.
      assert {:ok, [_]} = Ash.read(Post, actor: actor(role: :customer))
      assert {:ok, %Post{}} = Ash.get(Post, post.id, actor: actor(role: :customer))
    end
  end

  describe "composition with existing policies" do
    setup do
      set_flag("publishing-v2", true)
      :ok
    end

    test "the resource's own role rule still applies when the flag is on" do
      # A customer is refused by the resource's policy, not by the flag.
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(Post, %{title: "Draft"}, actor: actor(role: :customer))

      assert {:ok, _} = Ash.create(Post, %{title: "Draft"}, actor: actor(role: :editor))
    end

    test "the flag still applies to actors the role rule allows" do
      set_flag("publishing-v2", false)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(Post, %{title: "Draft"}, actor: actor(role: :editor))
    end

    test "guard and role rule are AND, not OR" do
      for {role, flag, expected} <- [
            {:editor, true, :ok},
            {:editor, false, :error},
            {:customer, true, :error},
            {:customer, false, :error}
          ] do
        set_flag("publishing-v2", flag)

        result =
          case Ash.create(Post, %{title: "t"}, actor: actor(role: role)) do
            {:ok, _} -> :ok
            {:error, _} -> :error
          end

        assert result == expected,
               "role=#{role} flag=#{flag} expected #{expected}, got #{result}"
      end
    end
  end

  describe "enabled_for_roles" do
    test "admins bypass the provider entirely" do
      set_flag("publishing-v2", false)

      # `flag :publishing_v2 do enabled_for_roles [:admin] end`
      assert {:ok, _} = Ash.create(Post, %{title: "Draft"}, actor: actor(role: :admin))
      assert {:error, _} = Ash.create(Post, %{title: "Draft"}, actor: actor(role: :editor))
    end

    test "reads roles from a list attribute too" do
      set_flag("publishing-v2", false)

      assert {:ok, _} =
               Ash.create(Post, %{title: "Draft"},
                 actor: actor(role: :editor, roles: ["writer", "admin"])
               )
    end
  end

  describe "custom messages" do
    test "the declared message reaches the caller" do
      set_flag("publishing-v2", false)

      {:error, error} = Ash.create(Post, %{title: "Draft"}, actor: actor(role: :editor))

      assert Exception.message(error) =~ "Post creation is paused"
    end
  end

  describe "Ash.can?" do
    test "reflects the flag, so UIs can hide the button" do
      set_flag("publishing-v2", false)
      refute Ash.can?({Post, :create, %{title: "x"}}, actor(role: :editor))

      set_flag("publishing-v2", true)
      assert Ash.can?({Post, :create, %{title: "x"}}, actor(role: :editor))
    end
  end

  describe "update actions" do
    setup do
      set_flag("publishing-v2", true)
      {:ok, post} = Ash.create(Post, %{title: "Draft"}, actor: actor(role: :editor))
      %{post: post}
    end

    test "publish is gated", %{post: post} do
      set_flag("publishing-v2", false)

      assert {:error, %Ash.Error.Forbidden{}} =
               post
               |> Ash.Changeset.for_update(:publish, %{})
               |> Ash.update(actor: actor(role: :editor))

      set_flag("publishing-v2", true)

      assert {:ok, %Post{body: "published"}} =
               post
               |> Ash.Changeset.for_update(:publish, %{})
               |> Ash.update(actor: actor(role: :editor))
    end

    test "the unguarded update action is unaffected", %{post: post} do
      set_flag("publishing-v2", false)

      assert {:ok, %Post{title: "Renamed"}} =
               post
               |> Ash.Changeset.for_update(:update, %{title: "Renamed"})
               |> Ash.update(actor: actor(role: :editor))
    end
  end
end
