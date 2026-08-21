defmodule AshFeatureFlags.ActionGuard do
  @moduledoc """
  Declares that one or more actions are only usable while a flag is on.

  Produced by `guard_action` in the `feature_flags` DSL section.
  """

  defstruct [
    :flag,
    :variant,
    :message,
    :description,
    actions: [],
    match: :all,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          flag: [atom()],
          variant: String.t() | nil,
          message: String.t() | nil,
          description: String.t() | nil,
          actions: [atom()],
          match: :all | :any
        }

  @doc false
  def transform(%__MODULE__{} = guard) do
    {:ok, %{guard | actions: List.wrap(guard.actions), flag: List.wrap(guard.flag)}}
  end
end

defmodule AshFeatureFlags.AttributeGuard do
  @moduledoc """
  Declares that one or more fields are only visible while a flag is on.

  Produced by `guard_attribute` in the `feature_flags` DSL section. When the
  flag is off the field is replaced with `%Ash.ForbiddenField{}` in results and
  reads as `nil` in filters, which is Ash's standard field-policy behaviour.
  """

  defstruct [
    :flag,
    :variant,
    :description,
    attributes: [],
    match: :all,
    prevent_filtering?: true,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          flag: [atom()],
          variant: String.t() | nil,
          description: String.t() | nil,
          attributes: [atom()],
          match: :all | :any,
          prevent_filtering?: boolean()
        }

  @doc false
  def transform(%__MODULE__{} = guard) do
    {:ok, %{guard | attributes: List.wrap(guard.attributes), flag: List.wrap(guard.flag)}}
  end
end
