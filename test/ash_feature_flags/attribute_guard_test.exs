defmodule AshFeatureFlags.AttributeGuardTest do
  use AshFeatureFlags.Case, async: false

  require Ash.Query

  setup do
    set_flag("publishing-v2", true)

    {:ok, post} =
      Ash.create(
        Post,
        %{
          title: "Draft",
          body: "words",
          predicted_engagement: 0.87,
          internal_notes: "customer is upset"
        },
        actor: actor(role: :editor)
      )

    %{post: post}
  end

  describe "guard_attribute" do
    test "the field reads as ForbiddenField while the flag is off" do
      set_flag("ml-scoring", false)

      {:ok, [post]} = Ash.read(Post, actor: actor(role: :customer))

      assert %Ash.ForbiddenField{field: :predicted_engagement} = post.predicted_engagement
    end

    test "the field reads normally once the flag is on" do
      set_flag("ml-scoring", true)

      {:ok, [post]} = Ash.read(Post, actor: actor(role: :customer))

      assert post.predicted_engagement == 0.87
    end

    test "each guarded field follows its own flag" do
      set_flag("ml-scoring", true)
      set_flag("support-tooling", false)

      {:ok, [post]} = Ash.read(Post, actor: actor(role: :customer))

      assert post.predicted_engagement == 0.87
      assert %Ash.ForbiddenField{} = post.internal_notes
    end

    test "unguarded fields are never hidden" do
      set_flag("ml-scoring", false)
      set_flag("support-tooling", false)

      {:ok, [post]} = Ash.read(Post, actor: actor(role: :customer))

      # The catch-all field policy the extension adds must keep everything
      # else visible; Ash would otherwise demand coverage of every field.
      assert post.title == "Draft"
      assert post.body == "words"
      refute match?(%Ash.ForbiddenField{}, post.title)
    end

    test "primary keys stay readable, as Ash guarantees", %{post: created} do
      set_flag("ml-scoring", false)

      {:ok, [post]} = Ash.read(Post, actor: actor(role: :customer))

      assert post.id == created.id
    end
  end

  describe "filtering on a guarded field" do
    test "filtering on a hidden field is refused, not silently answered" do
      # Hiding the value is not enough on its own: `filter(x > 0.5)` narrows
      # the result set and leaks the value a bisection at a time. That is what
      # `prevent_filtering?` (on by default) closes.
      set_flag("ml-scoring", false)

      assert {:error, %Ash.Error.Forbidden{}} =
               Post
               |> Ash.Query.filter(predicted_engagement > 0.5)
               |> Ash.read(actor: actor(role: :customer))
    end

    test "filtering works normally once the flag is on" do
      set_flag("ml-scoring", true)

      {:ok, results} =
        Post
        |> Ash.Query.filter(predicted_engagement > 0.5)
        |> Ash.read(actor: actor(role: :customer))

      assert length(results) == 1
    end

    test "filtering on unguarded fields is never affected" do
      set_flag("ml-scoring", false)

      {:ok, results} =
        Post
        |> Ash.Query.filter(title == "Draft")
        |> Ash.read(actor: actor(role: :customer))

      assert length(results) == 1
    end
  end

  describe "roles and field visibility" do
    test "enabled_for_roles applies to fields as well as actions" do
      # `support_tooling` has no role short-circuit, `publishing_v2` does;
      # use a field guarded by a role-privileged flag to prove the path.
      set_flag("ml-scoring", false)

      {:ok, [post]} = Ash.read(Post, actor: actor(role: :admin))
      assert %Ash.ForbiddenField{} = post.predicted_engagement

      set_flag("ml-scoring", fn context -> :admin in context.roles end)

      {:ok, [admin_view]} = Ash.read(Post, actor: actor(role: :admin))
      {:ok, [customer_view]} = Ash.read(Post, actor: actor(role: :customer))

      assert admin_view.predicted_engagement == 0.87
      assert %Ash.ForbiddenField{} = customer_view.predicted_engagement
    end
  end
end
