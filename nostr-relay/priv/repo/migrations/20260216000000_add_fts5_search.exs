defmodule Nostr.Relay.Repo.Migrations.AddFts5Search do
  use Ecto.Migration

  def up do
    # FTS5 virtual table indexing events.content via external content (no duplication).
    # Uses implicit rowid from the events table as content_rowid.
    # unicode61 tokenizer with diacritics removal for multilingual content.
    execute("""
    CREATE VIRTUAL TABLE events_fts USING fts5(
      content,
      content='events',
      content_rowid='rowid',
      tokenize='unicode61 remove_diacritics 2'
    )
    """)

    # Triggers to keep FTS index in sync with the events table.
    # These fire inside the same transaction as the Ecto DML.

    execute("""
    CREATE TRIGGER events_fts_insert AFTER INSERT ON events BEGIN
      INSERT INTO events_fts(rowid, content) VALUES (new.rowid, new.content);
    END
    """)

    execute("""
    CREATE TRIGGER events_fts_delete AFTER DELETE ON events BEGIN
      INSERT INTO events_fts(events_fts, rowid, content)
        VALUES ('delete', old.rowid, old.content);
    END
    """)

    execute("""
    CREATE TRIGGER events_fts_update AFTER UPDATE ON events BEGIN
      INSERT INTO events_fts(events_fts, rowid, content)
        VALUES ('delete', old.rowid, old.content);
      INSERT INTO events_fts(rowid, content) VALUES (new.rowid, new.content);
    END
    """)

    # Backfill existing rows (for dev databases that already have data)
    execute("INSERT INTO events_fts(rowid, content) SELECT rowid, content FROM events")
  end

  def down do
    execute("DROP TRIGGER IF EXISTS events_fts_update")
    execute("DROP TRIGGER IF EXISTS events_fts_delete")
    execute("DROP TRIGGER IF EXISTS events_fts_insert")
    execute("DROP TABLE IF EXISTS events_fts")
  end
end
