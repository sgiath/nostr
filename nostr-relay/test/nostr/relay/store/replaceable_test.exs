defmodule Nostr.Relay.Store.ReplaceableTest do
  use Nostr.Relay.DataCase, async: false

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Relay.Store
  alias Nostr.Relay.Store.Event, as: EventRecord
  alias Nostr.Tag

  @seckey_a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @seckey_b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  setup do
    Store.clear([])
    :ok
  end

  # --- helpers ---

  defp build_event(opts) do
    kind = Keyword.get(opts, :kind, 1)
    created_at = Keyword.get(opts, :created_at, ~U[2024-06-15 12:00:00Z])
    seckey = Keyword.get(opts, :seckey, @seckey_a)
    tags = Keyword.get(opts, :tags, [])
    content = Keyword.get(opts, :content, "test")

    Event.create(kind, created_at: created_at, tags: tags, content: content)
    |> Event.sign(seckey)
  end

  defp insert!(opts) do
    event = build_event(opts)
    :ok = Store.insert_event(event, [])
    event
  end

  defp stored_event_ids do
    Repo.all(EventRecord)
    |> Enum.map(& &1.event_id)
    |> Enum.sort()
  end

  defp query_ids(filter) do
    {:ok, events} = Store.query_events([filter], [])
    Enum.map(events, & &1.id) |> Enum.sort()
  end

  # --- ephemeral events ---

  describe "ephemeral events" do
    test "kind 20000 hidden by read filters" do
      event = insert!(kind: 20_000)
      assert event.id in stored_event_ids()
      assert query_ids(%Filter{ids: [event.id]}) == []
    end

    test "kind 29999 hidden by read filters" do
      event = insert!(kind: 29_999)
      assert event.id in stored_event_ids()
      assert query_ids(%Filter{ids: [event.id]}) == []
    end
  end

  # --- regular events (regression) ---

  describe "regular events" do
    test "kind 1 inserts normally" do
      event = insert!(kind: 1)
      assert query_ids(%Filter{ids: [event.id]}) == [event.id]
    end

    test "duplicate event_id returns :duplicate with one row" do
      event = insert!(kind: 1)
      assert :duplicate = Store.insert_event(event, [])
      assert stored_event_ids() == [event.id]
    end
  end

  # --- replaceable events (kinds 0, 3, 10000-19999) ---

  describe "replaceable events" do
    test "first insert stores" do
      event = insert!(kind: 0)
      assert query_ids(%Filter{kinds: [0]}) == [event.id]
    end

    test "newer remains newest in query results, older is preserved" do
      old = insert!(kind: 0, created_at: ~U[2024-06-15 12:00:00Z])
      new = build_event(kind: 0, created_at: ~U[2024-06-16 12:00:00Z])

      assert :ok = Store.insert_event(new, [])

      ids = query_ids(%Filter{kinds: [0]})
      assert ids == [new.id]
      assert old.id in stored_event_ids()
      assert new.id in stored_event_ids()
    end

    test "older is appended and still not visible in query result" do
      new = insert!(kind: 0, created_at: ~U[2024-06-16 12:00:00Z])
      old = build_event(kind: 0, created_at: ~U[2024-06-15 12:00:00Z])

      assert :ok = Store.insert_event(old, [])
      assert query_ids(%Filter{kinds: [0]}) == [new.id]
      assert old.id in stored_event_ids()
      assert new.id in stored_event_ids()
    end

    test "same timestamp keeps lowest id visible" do
      ts = ~U[2024-06-15 12:00:00Z]

      e1 = build_event(kind: 0, created_at: ts, content: "first")
      e2 = build_event(kind: 0, created_at: ts, content: "second")

      :ok = Store.insert_event(e1, [])
      Store.insert_event(e2, [])

      winner = if e1.id < e2.id, do: e1, else: e2
      assert query_ids(%Filter{kinds: [0]}) == [winner.id]
      assert e1.id in stored_event_ids()
      assert e2.id in stored_event_ids()
    end

    test "different pubkeys coexist" do
      e1 = insert!(kind: 0, seckey: @seckey_a)
      e2 = insert!(kind: 0, seckey: @seckey_b, created_at: ~U[2024-06-16 12:00:00Z])

      assert length(stored_event_ids()) == 2
      ids = query_ids(%Filter{kinds: [0]})
      assert e1.id in ids
      assert e2.id in ids
    end

    test "different kinds coexist" do
      e1 = insert!(kind: 0)
      e2 = insert!(kind: 3, created_at: ~U[2024-06-16 12:00:00Z])

      ids = stored_event_ids()
      assert e1.id in ids
      assert e2.id in ids
    end

    test "kind 3 is replaceable" do
      _old = insert!(kind: 3, created_at: ~U[2024-06-15 12:00:00Z])
      new = insert!(kind: 3, created_at: ~U[2024-06-16 12:00:00Z])

      assert query_ids(%Filter{kinds: [3]}) == [new.id]
    end

    test "kind 10000 boundary — replaceable" do
      _old = insert!(kind: 10_000, created_at: ~U[2024-06-15 12:00:00Z])
      new = insert!(kind: 10_000, created_at: ~U[2024-06-16 12:00:00Z])

      assert query_ids(%Filter{kinds: [10_000]}) == [new.id]
    end

    test "kind 19999 boundary — replaceable" do
      _old = insert!(kind: 19_999, created_at: ~U[2024-06-15 12:00:00Z])
      new = insert!(kind: 19_999, created_at: ~U[2024-06-16 12:00:00Z])

      assert query_ids(%Filter{kinds: [19_999]}) == [new.id]
    end
  end

  # --- parameterized replaceable events (kinds 30000-39999) ---

  describe "parameterized replaceable events" do
    test "first insert stores" do
      event = insert!(kind: 30_000, tags: [Tag.create(:d, "abc")])
      assert query_ids(%Filter{kinds: [30_000]}) == [event.id]
    end

    test "same d-tag keeps newest in query result" do
      old =
        insert!(
          kind: 30_000,
          tags: [Tag.create(:d, "abc")],
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      new =
        insert!(
          kind: 30_000,
          tags: [Tag.create(:d, "abc")],
          created_at: ~U[2024-06-16 12:00:00Z]
        )

      ids = query_ids(%Filter{kinds: [30_000]})
      assert ids == [new.id]
      assert old.id in stored_event_ids()
      assert new.id in stored_event_ids()
    end

    test "older with same d-tag is appended and returns :ok" do
      _new =
        insert!(
          kind: 30_000,
          tags: [Tag.create(:d, "abc")],
          created_at: ~U[2024-06-16 12:00:00Z]
        )

      old =
        build_event(
          kind: 30_000,
          tags: [Tag.create(:d, "abc")],
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      assert :ok = Store.insert_event(old, [])
      assert old.id in stored_event_ids()
    end

    test "different d-tags coexist" do
      e1 =
        insert!(
          kind: 30_000,
          tags: [Tag.create(:d, "abc")],
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      e2 =
        insert!(
          kind: 30_000,
          tags: [Tag.create(:d, "xyz")],
          created_at: ~U[2024-06-16 12:00:00Z]
        )

      ids = query_ids(%Filter{kinds: [30_000]})
      assert e1.id in ids
      assert e2.id in ids
    end

    test "same d-tag, same timestamp — lower id wins" do
      ts = ~U[2024-06-15 12:00:00Z]

      e1 = build_event(kind: 30_000, tags: [Tag.create(:d, "abc")], created_at: ts, content: "a")
      e2 = build_event(kind: 30_000, tags: [Tag.create(:d, "abc")], created_at: ts, content: "b")

      :ok = Store.insert_event(e1, [])
      Store.insert_event(e2, [])

      winner = if e1.id < e2.id, do: e1, else: e2
      assert query_ids(%Filter{kinds: [30_000]}) == [winner.id]
      assert e1.id in stored_event_ids()
      assert e2.id in stored_event_ids()
    end

    test "empty d-tag replacement works" do
      old =
        insert!(
          kind: 30_000,
          tags: [Tag.create(:d, "")],
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      new =
        insert!(
          kind: 30_000,
          tags: [Tag.create(:d, "")],
          created_at: ~U[2024-06-16 12:00:00Z]
        )

      ids = query_ids(%Filter{kinds: [30_000]})
      assert ids == [new.id]
      assert old.id in stored_event_ids()
      assert new.id in stored_event_ids()
    end

    test "missing d-tag treated as empty string" do
      old =
        insert!(
          kind: 30_000,
          tags: [],
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      new =
        insert!(
          kind: 30_000,
          tags: [],
          created_at: ~U[2024-06-16 12:00:00Z]
        )

      ids = query_ids(%Filter{kinds: [30_000]})
      assert ids == [new.id]
      assert old.id in stored_event_ids()
      assert new.id in stored_event_ids()
    end

    test "different pubkeys with same d-tag coexist" do
      e1 =
        insert!(
          kind: 30_000,
          tags: [Tag.create(:d, "abc")],
          seckey: @seckey_a
        )

      e2 =
        insert!(
          kind: 30_000,
          tags: [Tag.create(:d, "abc")],
          seckey: @seckey_b,
          created_at: ~U[2024-06-16 12:00:00Z]
        )

      ids = query_ids(%Filter{kinds: [30_000]})
      assert e1.id in ids
      assert e2.id in ids
    end

    test "kind 30000 boundary — parameterized replaceable" do
      _old =
        insert!(
          kind: 30_000,
          tags: [Tag.create(:d, "x")],
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      new =
        insert!(
          kind: 30_000,
          tags: [Tag.create(:d, "x")],
          created_at: ~U[2024-06-16 12:00:00Z]
        )

      assert query_ids(%Filter{kinds: [30_000]}) == [new.id]
    end

    test "kind 39999 boundary — parameterized replaceable" do
      _old =
        insert!(
          kind: 39_999,
          tags: [Tag.create(:d, "x")],
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      new =
        insert!(
          kind: 39_999,
          tags: [Tag.create(:d, "x")],
          created_at: ~U[2024-06-16 12:00:00Z]
        )

      assert query_ids(%Filter{kinds: [39_999]}) == [new.id]
    end
  end

  # --- kind boundary classification ---

  describe "kind boundary classification" do
    test "kind 9999 is regular — no replacement" do
      e1 = insert!(kind: 9_999, created_at: ~U[2024-06-15 12:00:00Z])
      e2 = insert!(kind: 9_999, created_at: ~U[2024-06-16 12:00:00Z])

      ids = query_ids(%Filter{kinds: [9_999]})
      assert e1.id in ids
      assert e2.id in ids
    end

    test "kind 19999 is replaceable, kind 20000 is ephemeral" do
      replaceable = insert!(kind: 19_999, created_at: ~U[2024-06-15 12:00:00Z])
      ephemeral = insert!(kind: 20_000, created_at: ~U[2024-06-16 12:00:00Z])

      assert query_ids(%Filter{kinds: [19_999]}) == [replaceable.id]
      assert query_ids(%Filter{kinds: [20_000]}) == []
      assert ephemeral.id in stored_event_ids()
    end

    test "kind 29999 is ephemeral, kind 30000 is parameterized replaceable" do
      ephemeral = insert!(kind: 29_999)

      param =
        insert!(kind: 30_000, tags: [Tag.create(:d, "x")], created_at: ~U[2024-06-16 12:00:00Z])

      assert ephemeral.id in stored_event_ids()
      assert query_ids(%Filter{kinds: [30_000]}) == [param.id]
    end

    test "kind 39999 is parameterized replaceable, kind 40000 is regular" do
      p1 =
        insert!(kind: 39_999, tags: [Tag.create(:d, "x")], created_at: ~U[2024-06-15 12:00:00Z])

      p2 =
        insert!(kind: 39_999, tags: [Tag.create(:d, "x")], created_at: ~U[2024-06-16 12:00:00Z])

      # 39999: only latest survives
      assert query_ids(%Filter{kinds: [39_999]}) == [p2.id]
      assert p1.id in stored_event_ids()
      assert p2.id in stored_event_ids()

      # 40000: both survive (regular)
      r1 = insert!(kind: 40_000, created_at: ~U[2024-06-17 12:00:00Z])
      r2 = insert!(kind: 40_000, created_at: ~U[2024-06-18 12:00:00Z])

      ids = query_ids(%Filter{kinds: [40_000]})
      assert r1.id in ids
      assert r2.id in ids
    end
  end
end
