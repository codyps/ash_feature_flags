defmodule ExampleApp.Repo.Migrations.Initial do
  @moduledoc """
  Hand-written rather than generated, so the example has no snapshot machinery
  to explain. In a real app you would run `mix ash_sqlite.generate_migrations`.
  """

  use Ecto.Migration

  def up do
    create table(:users, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:email, :text, null: false)
      add(:role, :text, null: false, default: "customer")
    end

    create unique_index(:users, [:email], name: "users_unique_email_index")

    create table(:orders, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:reference, :text, null: false)
      add(:total_cents, :bigint, null: false, default: 0)
      add(:express?, :boolean, null: false, default: false)
      add(:gift_wrapped?, :boolean, null: false, default: false)
      add(:predicted_ltv, :bigint)
      add(:fraud_notes, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)

      add(
        :customer_id,
        references(:users, column: :id, type: :uuid, on_delete: :delete_all),
        null: false
      )
    end

    create table(:feature_flags, primary_key: false) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:key, :text, null: false)
      add(:description, :text)
      add(:enabled, :boolean, null: false, default: false)
      add(:rollout_percentage, :bigint)
      add(:allowed_roles, :map, null: false, default: "[]")
      add(:allowed_tenants, :map, null: false, default: "[]")
      add(:variant, :text)
      add(:metadata, :map, null: false, default: "{}")
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create unique_index(:feature_flags, [:key], name: "feature_flags_unique_key_index")
  end

  def down do
    drop(table(:feature_flags))
    drop(table(:orders))
    drop(table(:users))
  end
end
