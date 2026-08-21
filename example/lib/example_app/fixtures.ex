defmodule ExampleApp.Fixtures do
  @moduledoc """
  The three actors and the one order every scenario runs against.

  Deterministic ids, so a percentage rollout puts the same people in the same
  cohort on every run and the demo output is stable enough to diff.
  """

  require Ash.Query

  @customer_id "11111111-1111-1111-1111-111111111111"
  @support_id "22222222-2222-2222-2222-222222222222"
  @admin_id "33333333-3333-3333-3333-333333333333"

  @order_reference "ORD-1001"

  @doc """
  The world, built only if it is not already there.

  `reset!/0` is destructive, which is what `mix demo` wants and what a web page
  anyone might refresh does not. The LiveView playground calls this on mount.
  """
  @spec ensure!() :: %{
          customer: struct(),
          support: struct(),
          admin: struct(),
          order: struct()
        }
  def ensure! do
    with {:ok, customer} when not is_nil(customer) <- fetch_user(@customer_id),
         {:ok, support} when not is_nil(support) <- fetch_user(@support_id),
         {:ok, admin} when not is_nil(admin) <- fetch_user(@admin_id),
         {:ok, order} when not is_nil(order) <- fetch_order() do
      %{customer: customer, support: support, admin: admin, order: order}
    else
      _ -> reset!()
    end
  end

  @doc "Wipes and rebuilds the world. Returns the actors and the order."
  @spec reset!() :: %{
          customer: struct(),
          support: struct(),
          admin: struct(),
          order: struct()
        }
  def reset! do
    Ash.bulk_destroy!(ExampleApp.Shop.Order, :destroy, %{},
      authorize?: false,
      strategy: [:stream],
      return_errors?: true
    )

    Ash.bulk_destroy!(ExampleApp.Accounts.User, :destroy, %{},
      authorize?: false,
      strategy: [:stream],
      return_errors?: true
    )

    customer = user!(@customer_id, "ada@example.com", :customer)
    support = user!(@support_id, "sam@example.com", :support)
    admin = user!(@admin_id, "root@example.com", :admin)

    order =
      ExampleApp.Shop.Order
      |> Ash.Changeset.for_create(:create, %{
        reference: @order_reference,
        total_cents: 12_900,
        customer_id: customer.id,
        predicted_ltv: 480,
        fraud_notes: "Card issued in a different country to the shipping address."
      })
      |> Ash.create!(authorize?: false)

    %{customer: customer, support: support, admin: admin, order: order}
  end

  @doc """
  Throwaway actors for the rollout check.

  Unpersisted: the flag providers only ever read the actor's id and role, so
  there is no reason to touch the database 200 times.
  """
  @spec rollout_actors(pos_integer()) :: [struct()]
  def rollout_actors(count) do
    for index <- 1..count do
      struct(ExampleApp.Accounts.User, %{
        id: deterministic_uuid(index),
        email: "shopper#{index}@example.com",
        role: :customer
      })
    end
  end

  defp fetch_user(id) do
    ExampleApp.Accounts.User
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(authorize?: false)
  end

  defp fetch_order do
    ExampleApp.Shop.Order
    |> Ash.Query.filter(reference == ^@order_reference)
    |> Ash.read_one(authorize?: false)
  end

  defp user!(id, email, role) do
    ExampleApp.Accounts.User
    |> Ash.Changeset.for_create(:create, %{email: email, role: role})
    |> Ash.Changeset.force_change_attribute(:id, id)
    |> Ash.create!(authorize?: false)
  end

  defp deterministic_uuid(index) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> =
      :crypto.hash(:md5, "shopper-#{index}") |> Base.encode16(case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end
end
