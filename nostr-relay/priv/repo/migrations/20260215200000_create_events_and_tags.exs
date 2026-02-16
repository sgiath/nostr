defmodule Nostr.Relay.Repo.Migrations.CreateEventsAndTags do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :event_id, :text, primary_key: true
      add :pubkey, :text, null: false
      add :kind, :integer, null: false
      add :created_at, :integer, null: false
      add :content, :text, null: false, default: ""
      add :raw_json, :binary, null: false
    end

    create index(:events, [:pubkey])
    create index(:events, [:kind])
    create index(:events, [:pubkey, :kind])

    execute("CREATE INDEX idx_events_created_at ON events(created_at DESC)")
    execute("CREATE INDEX idx_events_kind_created_at ON events(kind, created_at DESC)")

    create table(:event_tags) do
      add :event_id,
          references(:events, column: :event_id, type: :text, on_delete: :delete_all),
          null: false

      add :tag_name, :text, null: false
      add :tag_value, :text, null: false
    end

    create index(:event_tags, [:tag_name, :tag_value])
    create index(:event_tags, [:event_id])
  end
end
