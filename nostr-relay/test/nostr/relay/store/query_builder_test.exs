defmodule Nostr.Relay.Store.QueryBuilderTest do
  use Nostr.Relay.DataCase, async: false

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Relay.Store
  alias Nostr.Relay.Store.QueryBuilder
  alias Nostr.Tag

  # These are secret keys — Event.sign/2 derives the actual pubkey
  @seckey_a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @seckey_b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  setup do
    Store.clear([])
    :ok
  end

  # --- helpers ---

  defp insert!(opts \\ []) do
    kind = Keyword.get(opts, :kind, 1)
    created_at = Keyword.get(opts, :created_at, ~U[2024-06-15 12:00:00Z])
    seckey = Keyword.get(opts, :seckey, @seckey_a)
    tags = Keyword.get(opts, :tags, [])
    content = Keyword.get(opts, :content, "test")

    event =
      Event.create(kind, created_at: created_at, tags: tags, content: content)
      |> Event.sign(seckey)

    :ok = Store.insert_event(event, [])
    event
  end

  defp query!(filter) do
    {:ok, records} = QueryBuilder.query_events([filter])
    records
  end

  defp event_ids(records), do: Enum.map(records, & &1.event_id)

  defp event_id_set(records) do
    records
    |> event_ids()
    |> MapSet.new()
  end

  # --- ids filter ---

  describe "ids filter" do
    test "exact match" do
      e1 = insert!()
      _e2 = insert!(created_at: ~U[2024-06-16 12:00:00Z])

      results = query!(%Filter{ids: [e1.id]})
      assert event_ids(results) == [e1.id]
    end

    test "prefix match" do
      e1 = insert!()
      prefix = String.slice(e1.id, 0, 8)

      results = query!(%Filter{ids: [prefix]})
      assert e1.id in event_ids(results)
    end

    test "multiple ids" do
      e1 = insert!(created_at: ~U[2024-06-15 12:00:00Z])
      e2 = insert!(created_at: ~U[2024-06-16 12:00:00Z])
      _e3 = insert!(created_at: ~U[2024-06-17 12:00:00Z])

      results = query!(%Filter{ids: [e1.id, e2.id]})
      assert length(results) == 2
      assert event_id_set(results) == MapSet.new([e1.id, e2.id])
    end

    test "no match returns empty" do
      insert!()

      results =
        query!(%Filter{ids: ["0000000000000000000000000000000000000000000000000000000000000000"]})

      assert results == []
    end
  end

  # --- authors filter ---

  describe "authors filter" do
    test "exact match" do
      e1 = insert!(seckey: @seckey_a)
      _e2 = insert!(seckey: @seckey_b, created_at: ~U[2024-06-16 12:00:00Z])

      results = query!(%Filter{authors: [e1.pubkey]})
      assert event_ids(results) == [e1.id]
    end

    test "prefix match" do
      e1 = insert!(seckey: @seckey_a)
      _e2 = insert!(seckey: @seckey_b, created_at: ~U[2024-06-16 12:00:00Z])

      prefix = String.slice(e1.pubkey, 0, 8)
      results = query!(%Filter{authors: [prefix]})
      assert event_ids(results) == [e1.id]
    end

    test "multiple authors" do
      e1 = insert!(seckey: @seckey_a, created_at: ~U[2024-06-15 12:00:00Z])
      e2 = insert!(seckey: @seckey_b, created_at: ~U[2024-06-16 12:00:00Z])

      results = query!(%Filter{authors: [e1.pubkey, e2.pubkey]})
      assert length(results) == 2
      assert event_id_set(results) == MapSet.new([e1.id, e2.id])
    end
  end

  # --- kinds filter ---

  describe "kinds filter" do
    test "single kind" do
      e1 = insert!(kind: 1)
      _e2 = insert!(kind: 7, created_at: ~U[2024-06-16 12:00:00Z])

      results = query!(%Filter{kinds: [1]})
      assert event_ids(results) == [e1.id]
    end

    test "multiple kinds" do
      e1 = insert!(kind: 1, created_at: ~U[2024-06-15 12:00:00Z])
      _e2 = insert!(kind: 7, created_at: ~U[2024-06-16 12:00:00Z])
      e3 = insert!(kind: 3, created_at: ~U[2024-06-17 12:00:00Z])

      results = query!(%Filter{kinds: [1, 3]})
      assert event_id_set(results) == MapSet.new([e1.id, e3.id])
    end
  end

  # --- since / until ---

  describe "since filter" do
    test "includes events at boundary" do
      e1 = insert!(created_at: ~U[2024-06-15 12:00:00Z])
      _e2 = insert!(created_at: ~U[2024-06-14 12:00:00Z], seckey: @seckey_b)

      results = query!(%Filter{since: ~U[2024-06-15 12:00:00Z]})
      assert event_ids(results) == [e1.id]
    end

    test "excludes events before since" do
      _e1 = insert!(created_at: ~U[2024-06-14 12:00:00Z])
      results = query!(%Filter{since: ~U[2024-06-15 12:00:00Z]})
      assert results == []
    end
  end

  describe "until filter" do
    test "includes events at boundary" do
      e1 = insert!(created_at: ~U[2024-06-15 12:00:00Z])
      _e2 = insert!(created_at: ~U[2024-06-16 12:00:00Z], seckey: @seckey_b)

      results = query!(%Filter{until: ~U[2024-06-15 12:00:00Z]})
      assert event_ids(results) == [e1.id]
    end
  end

  describe "since + until combined" do
    test "range query" do
      _e1 = insert!(created_at: ~U[2024-06-14 12:00:00Z])
      e2 = insert!(created_at: ~U[2024-06-15 12:00:00Z], seckey: @seckey_b)
      _e3 = insert!(created_at: ~U[2024-06-16 12:00:00Z])

      results =
        query!(%Filter{since: ~U[2024-06-15 00:00:00Z], until: ~U[2024-06-15 23:59:59Z]})

      assert event_ids(results) == [e2.id]
    end
  end

  # --- limit ---

  describe "limit" do
    test "respects limit count" do
      for i <- 1..5 do
        insert!(created_at: DateTime.add(~U[2024-06-15 12:00:00Z], i, :second))
      end

      results = query!(%Filter{limit: 3})
      assert length(results) == 3
    end

    test "returns newest first" do
      e_old = insert!(created_at: ~U[2024-06-14 12:00:00Z])
      e_new = insert!(created_at: ~U[2024-06-16 12:00:00Z], seckey: @seckey_b)

      results = query!(%Filter{limit: 2})
      assert event_ids(results) == [e_new.id, e_old.id]
    end
  end

  # --- ordering ---

  describe "ordering" do
    test "created_at DESC, event_id ASC for ties" do
      _e1 = insert!(created_at: ~U[2024-06-15 12:00:00Z])
      _e2 = insert!(created_at: ~U[2024-06-15 12:00:00Z], seckey: @seckey_b)
      e3 = insert!(created_at: ~U[2024-06-16 12:00:00Z])

      results = query!(%Filter{})
      ids = event_ids(results)

      # e3 is newest, e1 and e2 tie on time so sorted by event_id ASC
      assert List.first(ids) == e3.id
      [tied_a, tied_b] = Enum.drop(ids, 1)
      assert tied_a < tied_b
    end
  end

  # --- empty filter ---

  describe "empty filter" do
    test "returns all events" do
      e1 = insert!(created_at: ~U[2024-06-15 12:00:00Z])
      e2 = insert!(created_at: ~U[2024-06-16 12:00:00Z], seckey: @seckey_b)

      results = query!(%Filter{})
      assert length(results) == 2
      assert event_id_set(results) == MapSet.new([e1.id, e2.id])
    end
  end

  # --- AND within filter ---

  describe "AND semantics" do
    test "all conditions must match" do
      e1 =
        insert!(kind: 1, seckey: @seckey_a, created_at: ~U[2024-06-15 12:00:00Z])

      _e2 =
        insert!(kind: 7, seckey: @seckey_a, created_at: ~U[2024-06-16 12:00:00Z])

      _e3 =
        insert!(kind: 1, seckey: @seckey_b, created_at: ~U[2024-06-17 12:00:00Z])

      results = query!(%Filter{kinds: [1], authors: [e1.pubkey]})
      assert event_ids(results) == [e1.id]
    end
  end

  # --- tag filters ---

  describe "tag filters" do
    test "#e tag filter" do
      ref_id = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

      e1 =
        insert!(
          tags: [Tag.create(:e, ref_id)],
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      _e2 = insert!(created_at: ~U[2024-06-16 12:00:00Z], seckey: @seckey_b)

      filter = %Filter{} |> Map.put(:"#e", [ref_id])
      results = query!(filter)
      assert event_ids(results) == [e1.id]
    end

    test "#p tag filter" do
      target_pubkey = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

      e1 =
        insert!(
          tags: [Tag.create(:p, target_pubkey)],
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      _e2 = insert!(created_at: ~U[2024-06-16 12:00:00Z], seckey: @seckey_b)

      filter = %Filter{} |> Map.put(:"#p", [target_pubkey])
      results = query!(filter)
      assert event_ids(results) == [e1.id]
    end

    test "#d tag filter" do
      e1 =
        insert!(
          tags: [Tag.create(:d, "my-article")],
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      _e2 = insert!(created_at: ~U[2024-06-16 12:00:00Z], seckey: @seckey_b)

      filter = %Filter{} |> Map.put(:"#d", ["my-article"])
      results = query!(filter)
      assert event_ids(results) == [e1.id]
    end

    test "dynamic tag filter via filter.tags" do
      e1 =
        insert!(
          tags: [Tag.create(:t, "nostr")],
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      _e2 = insert!(created_at: ~U[2024-06-16 12:00:00Z], seckey: @seckey_b)

      filter = %Filter{tags: %{"#t" => ["nostr"]}}
      results = query!(filter)
      assert event_ids(results) == [e1.id]
    end

    test "multiple tag values (OR within a tag filter)" do
      e1 =
        insert!(
          tags: [Tag.create(:t, "nostr")],
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      e2 =
        insert!(
          tags: [Tag.create(:t, "bitcoin")],
          created_at: ~U[2024-06-16 12:00:00Z],
          seckey: @seckey_b
        )

      filter = %Filter{tags: %{"#t" => ["nostr", "bitcoin"]}}
      results = query!(filter)
      assert event_id_set(results) == MapSet.new([e1.id, e2.id])
    end

    test "multi-tag AND (different tag types)" do
      ref_id = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      target_pubkey = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

      e1 =
        insert!(
          tags: [Tag.create(:e, ref_id), Tag.create(:p, target_pubkey)],
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      _e2 =
        insert!(
          tags: [Tag.create(:e, ref_id)],
          created_at: ~U[2024-06-16 12:00:00Z],
          seckey: @seckey_b
        )

      filter =
        %Filter{}
        |> Map.put(:"#e", [ref_id])
        |> Map.put(:"#p", [target_pubkey])

      results = query!(filter)
      assert event_ids(results) == [e1.id]
    end

    test "event with multiple tags of same type" do
      e1 =
        insert!(
          tags: [Tag.create(:t, "nostr"), Tag.create(:t, "bitcoin")],
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      filter = %Filter{tags: %{"#t" => ["bitcoin"]}}
      results = query!(filter)
      assert event_ids(results) == [e1.id]
    end
  end

  # --- multi-filter OR ---

  describe "multi-filter OR" do
    test "results from multiple filters are merged" do
      e1 = insert!(kind: 1, created_at: ~U[2024-06-15 12:00:00Z])
      e2 = insert!(kind: 7, created_at: ~U[2024-06-16 12:00:00Z], seckey: @seckey_b)

      {:ok, results} =
        QueryBuilder.query_events([%Filter{kinds: [1]}, %Filter{kinds: [7]}])

      result_ids = event_id_set(results)
      expected_ids = MapSet.new([e1.id, e2.id])
      assert result_ids == expected_ids
    end

    test "duplicates are removed" do
      e1 = insert!(kind: 1, seckey: @seckey_a, created_at: ~U[2024-06-15 12:00:00Z])

      {:ok, results} =
        QueryBuilder.query_events([
          %Filter{kinds: [1]},
          %Filter{authors: [e1.pubkey]}
        ])

      assert event_ids(results) == [e1.id]
    end
  end

  # --- event_matches_filters? ---

  describe "event_matches_filters?/2" do
    test "returns true when event matches" do
      e1 = insert!(kind: 1)
      assert QueryBuilder.event_matches_filters?(e1.id, [%Filter{kinds: [1]}])
    end

    test "returns false when event does not match" do
      e1 = insert!(kind: 1)
      refute QueryBuilder.event_matches_filters?(e1.id, [%Filter{kinds: [7]}])
    end

    test "checks tag filters" do
      e1 = insert!(tags: [Tag.create(:t, "nostr")])

      assert QueryBuilder.event_matches_filters?(e1.id, [%Filter{tags: %{"#t" => ["nostr"]}}])
      refute QueryBuilder.event_matches_filters?(e1.id, [%Filter{tags: %{"#t" => ["other"]}}])
    end

    test "OR across filters" do
      e1 = insert!(kind: 1)

      assert QueryBuilder.event_matches_filters?(e1.id, [
               %Filter{kinds: [7]},
               %Filter{kinds: [1]}
             ])
    end
  end
end
