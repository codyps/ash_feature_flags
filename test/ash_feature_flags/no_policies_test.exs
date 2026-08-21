defmodule AshFeatureFlags.NoPoliciesTest do
  use AshFeatureFlags.Case, async: false

  require Ash.Query

  describe "a resource with guards but no policies of its own" do
    test "the guarded action is gated" do
      set_flag("archiving", true)
      {:ok, note} = Ash.create(Note, %{body: "hello"})

      set_flag("archiving", false)

      assert {:error, %Ash.Error.Forbidden{}} =
               note |> Ash.Changeset.for_update(:archive, %{}) |> Ash.update()

      set_flag("archiving", true)

      assert {:ok, %Note{archived: true}} =
               note |> Ash.Changeset.for_update(:archive, %{}) |> Ash.update()
    end

    test "every other action keeps working, as it did before the extension" do
      # Adding Ash.Policy.Authorizer would normally forbid anything no policy
      # authorizes. The catch-all we append keeps `unguarded_actions :allow`
      # honest.
      set_flag("archiving", false)

      assert {:ok, note} = Ash.create(Note, %{body: "hello"})
      assert {:ok, [_]} = Ash.read(Note)
      assert {:ok, _} = note |> Ash.Changeset.for_update(:update, %{body: "bye"}) |> Ash.update()
      assert :ok = Ash.destroy(note)
    end

    test "the authorizer is registered even though the resource never asked" do
      assert Ash.Policy.Authorizer in Ash.Resource.Info.authorizers(Note)
    end
  end

  describe "unguarded_actions :deny" do
    test "actions with no policy are forbidden" do
      set_flag("strict-reads", true)

      # :read is guarded, so it has a policy and passes.
      assert {:ok, []} = Ash.read(StrictNote)

      # :create has no policy at all, and nothing was added for it.
      assert {:error, %Ash.Error.Forbidden{}} = Ash.create(StrictNote, %{body: "x"})
    end

    test "the guard still applies" do
      set_flag("strict-reads", false)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(StrictNote)
    end
  end

  describe "prevent_filtering? false" do
    setup do
      set_flag("archiving", true)
      {:ok, _} = Ash.create(Note, %{body: "hello", score: 10})
      :ok
    end

    test "the value is still hidden while the flag is off" do
      set_flag("archiving", false)

      {:ok, [note]} = Ash.read(Note)
      assert %Ash.ForbiddenField{field: :score} = note.score
      assert note.body == "hello"
    end

    test "but filtering on it is allowed rather than refused" do
      set_flag("archiving", false)

      assert {:ok, [_]} =
               Note
               |> Ash.Query.filter(score > 5)
               |> Ash.read()
    end
  end
end
