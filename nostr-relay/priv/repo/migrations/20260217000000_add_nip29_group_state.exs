defmodule Nostr.Relay.Repo.Migrations.AddNip29GroupState do
  use Ecto.Migration

  def change do
    create table(:relay_groups, primary_key: false) do
      add :group_id, :text, primary_key: true
      add :managed, :boolean, null: false, default: false
      add :deleted, :boolean, null: false, default: false
      add :name, :text
      add :about, :text
      add :picture, :text
      add :private, :boolean, null: false, default: false
      add :restricted, :boolean, null: false, default: false
      add :hidden, :boolean, null: false, default: false
      add :closed, :boolean, null: false, default: false
      add :last_event_id, :text
      add :last_event_created_at, :integer
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:relay_group_memberships, primary_key: false) do
      add :group_id,
          references(:relay_groups, column: :group_id, type: :text, on_delete: :delete_all),
          null: false

      add :pubkey, :text, null: false
      add :status, :text, null: false, default: "member"
      add :last_event_id, :text
      add :last_event_created_at, :integer
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:relay_group_memberships, [:group_id, :pubkey])
    create index(:relay_group_memberships, [:pubkey])

    create table(:relay_group_roles, primary_key: false) do
      add :group_id,
          references(:relay_groups, column: :group_id, type: :text, on_delete: :delete_all),
          null: false

      add :pubkey, :text, null: false
      add :role, :text, null: false
      add :last_event_id, :text
      add :last_event_created_at, :integer
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:relay_group_roles, [:group_id, :pubkey, :role])
    create index(:relay_group_roles, [:group_id, :role])

    create table(:relay_group_invites, primary_key: false) do
      add :group_id,
          references(:relay_groups, column: :group_id, type: :text, on_delete: :delete_all),
          null: false

      add :code, :text, null: false
      add :created_by_pubkey, :text
      add :create_event_id, :text
      add :created_at, :integer
      add :consumed_by_pubkey, :text
      add :consumed_event_id, :text
      add :consumed_at, :integer
      add :revoked_at, :integer
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:relay_group_invites, [:group_id, :code])
    create index(:relay_group_invites, [:code])
  end
end
