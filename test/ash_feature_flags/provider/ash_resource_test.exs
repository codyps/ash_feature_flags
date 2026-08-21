defmodule AshFeatureFlags.Provider.AshResourceTest do
  use AshFeatureFlags.Case, async: false

  alias AshFeatureFlags.{Context, Flag}
  alias AshFeatureFlags.Provider.AshResource

  @opts [resource: AshFeatureFlags.Test.FeatureFlag]

  defp flag(attrs \\ []), do: struct(Flag, Keyword.merge([name: :new_checkout], attrs))

  defp insert(attrs) do
    FeatureFlag
    |> Ash.Changeset.for_create(:create, Map.new(attrs))
    |> Ash.create!(authorize?: false)
  end

  setup do
    on_exit(fn ->
      FeatureFlag
      |> Ash.read!(authorize?: false)
      |> Enum.each(&Ash.destroy!(&1, authorize?: false))
    end)

    :ok
  end

  describe "the FlagStore extension" do
    test "adds the standard columns" do
      names = FeatureFlag |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

      for expected <- [
            :id,
            :key,
            :description,
            :enabled,
            :rollout_percentage,
            :allowed_roles,
            :allowed_tenants,
            :variant,
            :metadata,
            :inserted_at,
            :updated_at
          ] do
        assert expected in names, "expected a #{inspect(expected)} attribute"
      end
    end

    test "adds CRUD plus a by_key read" do
      for action <- [:read, :create, :update, :destroy, :by_key] do
        assert Ash.Resource.Info.action(FeatureFlag, action), "expected a #{action} action"
      end
    end

    test "the by_key read is a get" do
      insert(key: "new-checkout", enabled: true)

      assert %{key: "new-checkout"} =
               FeatureFlag
               |> Ash.Query.for_read(:by_key, %{key: "new-checkout"})
               |> Ash.read_one!(authorize?: false)
    end
  end

  describe "enabled?/3" do
    test "reads the master switch" do
      insert(key: "new-checkout", enabled: true)
      assert {:ok, true} = AshResource.enabled?(flag(), Context.build([]), @opts)

      FeatureFlag
      |> Ash.read!(authorize?: false)
      |> hd()
      |> Ash.Changeset.for_update(:update, %{enabled: false})
      |> Ash.update!(authorize?: false)

      assert {:ok, false} = AshResource.enabled?(flag(), Context.build([]), @opts)
    end

    test "a missing row is an error, so the flag's default applies" do
      assert {:error, {:flag_not_found, "new-checkout"}} =
               AshResource.enabled?(flag(), Context.build([]), @opts)

      # ...and through the evaluator, that lands on the declared default.
      refute AshFeatureFlags.enabled?(:new_checkout, provider: {AshResource, @opts})
    end
  end

  describe "allowed_roles" do
    setup do
      insert(key: "new-checkout", enabled: true, rollout_percentage: 0, allowed_roles: ["admin"])
      :ok
    end

    test "an allowed role skips the rollout gate" do
      context = Context.build(actor: actor(role: :admin))
      assert {:ok, true} = AshResource.enabled?(flag(), context, @opts)
    end

    test "everyone else is subject to the rollout" do
      context = Context.build(actor: actor(role: :editor))
      assert {:ok, false} = AshResource.enabled?(flag(), context, @opts)
    end

    test "the master switch still wins over an allowed role" do
      FeatureFlag
      |> Ash.read!(authorize?: false)
      |> hd()
      |> Ash.Changeset.for_update(:update, %{enabled: false})
      |> Ash.update!(authorize?: false)

      context = Context.build(actor: actor(role: :admin))
      assert {:ok, false} = AshResource.enabled?(flag(), context, @opts)
    end
  end

  describe "allowed_tenants" do
    setup do
      insert(key: "new-checkout", enabled: true, allowed_tenants: ["acme"])
      :ok
    end

    test "restricts the flag to the listed tenants" do
      assert {:ok, true} = AshResource.enabled?(flag(), Context.build(tenant: "acme"), @opts)
      assert {:ok, false} = AshResource.enabled?(flag(), Context.build(tenant: "other"), @opts)
      assert {:ok, false} = AshResource.enabled?(flag(), Context.build([]), @opts)
    end
  end

  describe "rollout_percentage" do
    test "0 is off for everyone and 100 is on for everyone" do
      insert(key: "zero", enabled: true, rollout_percentage: 0)
      insert(key: "hundred", enabled: true, rollout_percentage: 100)

      for _ <- 1..20 do
        context = Context.build(actor: actor())
        assert {:ok, false} = AshResource.enabled?(flag(key: "zero"), context, @opts)
        assert {:ok, true} = AshResource.enabled?(flag(key: "hundred"), context, @opts)
      end
    end

    test "is stable for a given actor" do
      insert(key: "half", enabled: true, rollout_percentage: 50)
      context = Context.build(actor: actor())

      results =
        for _ <- 1..10 do
          {:ok, value} = AshResource.enabled?(flag(key: "half"), context, @opts)
          value
        end

      assert length(Enum.uniq(results)) == 1
    end

    test "lands roughly on the requested share of actors" do
      insert(key: "half", enabled: true, rollout_percentage: 50)

      enabled =
        Enum.count(1..400, fn _ ->
          context = Context.build(actor: actor())
          {:ok, value} = AshResource.enabled?(flag(key: "half"), context, @opts)
          value
        end)

      assert enabled in 150..250, "expected roughly half of 400, got #{enabled}"
    end

    test "two flags at the same percentage do not pick the same actors" do
      insert(key: "first", enabled: true, rollout_percentage: 50)
      insert(key: "second", enabled: true, rollout_percentage: 50)

      # Salting the hash with the flag key is what stops one unlucky cohort
      # from receiving every experiment at once.
      differing =
        Enum.count(1..200, fn _ ->
          context = Context.build(actor: actor())
          {:ok, a} = AshResource.enabled?(flag(key: "first"), context, @opts)
          {:ok, b} = AshResource.enabled?(flag(key: "second"), context, @opts)
          a != b
        end)

      assert differing > 50, "expected the two cohorts to diverge, only #{differing}/200 differed"
    end
  end

  describe "variant/3" do
    test "returns the stored variant when the flag is on" do
      insert(key: "new-checkout", enabled: true, variant: "treatment")

      assert {:ok, "treatment"} = AshResource.variant(flag(), Context.build([]), @opts)
    end

    test "returns nil when the flag is off" do
      insert(key: "new-checkout", enabled: false, variant: "treatment")

      assert {:ok, nil} = AshResource.variant(flag(), Context.build([]), @opts)
    end
  end

  describe "put/3" do
    test "flips the switch" do
      insert(key: "new-checkout", enabled: false)

      assert :ok = AshResource.put(flag(), true, @opts)
      assert {:ok, true} = AshResource.enabled?(flag(), Context.build([]), @opts)
    end
  end

  describe "as a resource's provider" do
    test "guards read from the database" do
      insert(key: "publishing-v2", enabled: false)

      opts = [provider: {AshResource, @opts}, resource: Post]
      refute AshFeatureFlags.enabled?(:publishing_v2, opts ++ [actor: actor(role: :editor)])

      # ...and the role short-circuit declared on the flag still wins.
      assert AshFeatureFlags.enabled?(:publishing_v2, opts ++ [actor: actor(role: :admin)])
    end
  end
end
