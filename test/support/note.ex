defmodule AshFeatureFlags.Test.Note do
  @moduledoc """
  A resource with guards but no policies and no authorizer of its own.

  Covers the "adding the extension should not lock down the rest of the
  resource" contract: `:read` stays open, `:archive` is gated.
  """

  use Ash.Resource,
    domain: AshFeatureFlags.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshFeatureFlags]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :body, :string, public?: true
    attribute :archived, :boolean, public?: true, default: false
    attribute :score, :integer, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    update :archive do
      accept []
      change set_attribute(:archived, true)
      require_atomic? false
    end
  end

  feature_flags do
    flag :archiving

    guard_action [:archive], flag: :archiving

    # Hidden from responses, but safe to filter on — so reads that mention it
    # are answered rather than refused.
    guard_attribute [:score], flag: :archiving, prevent_filtering?: false
  end
end

defmodule AshFeatureFlags.Test.StrictNote do
  @moduledoc """
  Same shape as `AshFeatureFlags.Test.Note`, but with
  `unguarded_actions :deny` — everything not explicitly authorized is
  forbidden, which is what you want once you are writing full policies.
  """

  use Ash.Resource,
    domain: AshFeatureFlags.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshFeatureFlags]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :body, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  feature_flags do
    unguarded_actions :deny

    flag :strict_reads

    guard_action [:read], flag: :strict_reads
  end
end
