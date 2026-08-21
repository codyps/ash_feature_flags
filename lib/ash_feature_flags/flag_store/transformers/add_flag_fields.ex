defmodule AshFeatureFlags.FlagStore.Transformers.AddFlagFields do
  @moduledoc """
  Adds the standard flag attributes, identity and actions to a resource using
  `AshFeatureFlags.FlagStore`.

  Everything is added with `add_new_*`, so anything you declare yourself takes
  precedence — override the `key` attribute's constraints, add your own
  `create` action with extra validations, and this transformer steps aside.
  """

  use Spark.Dsl.Transformer

  require Ash.Expr

  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def after?(_), do: false

  # Everything Ash derives from attributes and actions — the primary key cache,
  # default accepts, primary action selection — has to see what we added, so we
  # run before all of it.
  def before?(_), do: true

  def transform(dsl) do
    dsl
    |> add_primary_key()
    |> Builder.add_new_attribute(:key, :string,
      allow_nil?: false,
      public?: true,
      description: "The flag key, as referenced by `flag :name` or `key \"...\"`.",
      constraints: [min_length: 1, trim?: true]
    )
    |> Builder.add_new_attribute(:description, :string, public?: true)
    |> Builder.add_new_attribute(:enabled, :boolean,
      allow_nil?: false,
      default: false,
      public?: true,
      description: "Master switch. When false the flag is off for everyone."
    )
    |> Builder.add_new_attribute(:rollout_percentage, :integer,
      public?: true,
      constraints: [min: 0, max: 100],
      description:
        "Percentage of actors the flag is on for, by stable hash of their targeting key. `nil` means no rollout gate."
    )
    |> Builder.add_new_attribute(:allowed_roles, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true,
      description: "Roles the flag is on for regardless of the rollout percentage."
    )
    |> Builder.add_new_attribute(:allowed_tenants, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true,
      description: "When non-empty, the flag is only on for these tenants."
    )
    |> Builder.add_new_attribute(:variant, :string,
      public?: true,
      description: "Variant returned for multivariate flags."
    )
    |> Builder.add_new_attribute(:metadata, :map,
      allow_nil?: false,
      default: %{},
      public?: true
    )
    |> Builder.add_new_create_timestamp(:inserted_at, public?: true)
    |> Builder.add_new_update_timestamp(:updated_at, public?: true)
    |> Builder.add_new_identity(:unique_key, [:key])
    |> add_actions()
  end

  # Only add an id if the resource has no attributes yet at all — a resource
  # that already declares its own primary key (or uses a natural key of `key`)
  # should keep it.
  defp add_primary_key(dsl) do
    if Ash.Resource.Info.primary_key(dsl) == [] do
      Builder.add_new_attribute(dsl, :id, :uuid,
        primary_key?: true,
        allow_nil?: false,
        writable?: false,
        public?: true,
        default: &Ash.UUID.generate/0
      )
    else
      {:ok, dsl}
    end
  end

  defp add_actions(dsl) do
    dsl
    |> Builder.add_new_action(:read, :read, primary?: true)
    |> Builder.add_new_action(:create, :create,
      primary?: true,
      accept: [
        :key,
        :description,
        :enabled,
        :rollout_percentage,
        :allowed_roles,
        :allowed_tenants,
        :variant,
        :metadata
      ]
    )
    |> Builder.add_new_action(:update, :update,
      primary?: true,
      require_atomic?: false,
      accept: [
        :description,
        :enabled,
        :rollout_percentage,
        :allowed_roles,
        :allowed_tenants,
        :variant,
        :metadata
      ]
    )
    |> Builder.add_new_action(:destroy, :destroy, primary?: true)
    |> add_by_key_action()
  end

  # The read the provider uses. Declared here rather than filtered inline so
  # you can see it in AshAdmin and override it if your table is partitioned.
  defp add_by_key_action({:ok, dsl}), do: add_by_key_action(dsl)
  defp add_by_key_action({:error, error}), do: {:error, error}

  defp add_by_key_action(dsl) do
    if Ash.Resource.Info.action(dsl, :by_key) do
      {:ok, dsl}
    else
      with {:ok, argument} <-
             Transformer.build_entity(Ash.Resource.Dsl, [:actions, :read], :argument,
               name: :key,
               type: :string,
               allow_nil?: false
             ),
           {:ok, filter} <-
             Transformer.build_entity(Ash.Resource.Dsl, [:actions, :read], :filter,
               filter: Ash.Expr.expr(key == ^Ash.Expr.arg(:key))
             ) do
        Builder.add_action(dsl, :read, :by_key,
          get?: true,
          arguments: [argument],
          filters: [filter]
        )
      end
    end
  end
end
