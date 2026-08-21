defmodule AshFeatureFlags.ManualChecksTest do
  use AshFeatureFlags.Case, async: false

  alias AshFeatureFlags.Test.Comment

  describe "flag_enabled/1 in a hand-written policy" do
    test "composes as OR alongside a role check" do
      set_flag("public-commenting", false)

      # Admins pass on the role check alone.
      assert {:ok, _} = Ash.create(Comment, %{body: "hi"}, actor: actor(role: :admin))
      assert {:error, _} = Ash.create(Comment, %{body: "hi"}, actor: actor(role: :customer))

      set_flag("public-commenting", true)
      assert {:ok, _} = Ash.create(Comment, %{body: "hi"}, actor: actor(role: :customer))
    end

    test "works on a resource without the extension" do
      refute AshFeatureFlags in Spark.extensions(Comment)
    end
  end

  describe "flag_enabled/1 as a kill switch" do
    setup do
      set_flag("public-commenting", true)
      {:ok, comment} = Ash.create(Comment, %{body: "hi"}, actor: actor(role: :customer))
      %{comment: comment}
    end

    test "forbid_if freezes the action while the flag is on", %{comment: comment} do
      set_flag("comments-frozen", true)

      assert {:error, %Ash.Error.Forbidden{}} =
               comment
               |> Ash.Changeset.for_update(:update, %{body: "edited"})
               |> Ash.update(actor: actor(role: :admin))

      set_flag("comments-frozen", false)

      assert {:ok, _} =
               comment
               |> Ash.Changeset.for_update(:update, %{body: "edited"})
               |> Ash.update(actor: actor(role: :admin))
    end
  end

  describe "flag_variant/2 in a field policy" do
    setup do
      set_flag("public-commenting", true)
      {:ok, _} = Ash.create(Comment, %{body: "hi"}, actor: actor(role: :customer))
      :ok
    end

    test "the field is visible only for the named variant" do
      set_flag("comment-rendering", "plain")
      {:ok, [comment]} = Ash.read(Comment, actor: actor(role: :customer))
      assert %Ash.ForbiddenField{} = comment.body

      set_flag("comment-rendering", "rich")
      {:ok, [comment]} = Ash.read(Comment, actor: actor(role: :customer))
      assert comment.body == "hi"
    end
  end
end
