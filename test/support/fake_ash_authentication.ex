# `ash_authentication` is an optional integration, so it is not a dependency of
# this library. To still prove the seam works, we stand up modules with the
# same names and shapes it exposes — but only when the real package is absent,
# so adding it to a dev environment never collides.
unless Code.ensure_loaded?(AshAuthentication) do
  defmodule AshAuthentication.Info do
    @moduledoc false

    def authentication_subject_name(resource) do
      if function_exported?(resource, :__fake_subject_name__, 0) do
        {:ok, resource.__fake_subject_name__()}
      else
        :error
      end
    end
  end

  defmodule AshAuthentication do
    @moduledoc false

    def user_to_subject(%resource{} = record) do
      {:ok, subject_name} = AshAuthentication.Info.authentication_subject_name(resource)

      primary_key = Ash.Resource.Info.primary_key(resource)

      "#{subject_name}?#{URI.encode_query(Map.take(record, primary_key))}"
    end
  end
end

defmodule AshFeatureFlags.Test.AuthUser do
  @moduledoc """
  A user resource that looks like an `ash_authentication` one.
  """

  use Ash.Resource,
    domain: AshFeatureFlags.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :string, public?: true
    attribute :role, :atom, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  @doc false
  def __fake_subject_name__, do: :user
end
