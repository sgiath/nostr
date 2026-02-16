defmodule Nostr.FilterTest do
  use ExUnit.Case, async: true

  alias Nostr.Test.Fixtures

  doctest Nostr.Filter

  describe "parse/1" do
    test "parses filter with all fields" do
      raw = %{
        ids: ["id1", "id2"],
        authors: [Fixtures.pubkey()],
        kinds: [1, 2, 3],
        "#e": ["event_id"],
        "#p": ["pubkey"],
        "#a": ["address"],
        "#d": ["identifier"],
        since: 1_704_067_200,
        until: 1_704_153_600,
        limit: 100,
        search: "query"
      }

      filter = Nostr.Filter.parse(raw)

      assert filter.ids == ["id1", "id2"]
      assert filter.authors == [Fixtures.pubkey()]
      assert filter.kinds == [1, 2, 3]
      assert filter."#e" == ["event_id"]
      assert filter."#p" == ["pubkey"]
      assert filter."#a" == ["address"]
      assert filter."#d" == ["identifier"]
      assert filter.since == ~U[2024-01-01 00:00:00Z]
      assert filter.until == ~U[2024-01-02 00:00:00Z]
      assert filter.limit == 100
      assert filter.search == "query"
    end

    test "parses filter with minimal fields" do
      raw = %{kinds: [1]}
      filter = Nostr.Filter.parse(raw)

      assert filter.kinds == [1]
      assert filter.ids == nil
      assert filter.authors == nil
      assert filter.since == nil
      assert filter.until == nil
      assert filter.limit == nil
    end

    test "parses empty filter" do
      raw = %{}
      filter = Nostr.Filter.parse(raw)

      assert %Nostr.Filter{} = filter
    end

    test "converts unix timestamps to DateTime" do
      raw = %{since: 0, until: 1_000_000_000}
      filter = Nostr.Filter.parse(raw)

      assert filter.since == ~U[1970-01-01 00:00:00Z]
      assert filter.until == ~U[2001-09-09 01:46:40Z]
    end

    test "drops out-of-range timestamps instead of crashing" do
      raw = %{since: 9_223_372_036_854_775_807, until: 1_000_000_000}
      filter = Nostr.Filter.parse(raw)

      assert filter.since == nil
      assert filter.until == ~U[2001-09-09 01:46:40Z]
    end

    test "handles float timestamps from scientific notation" do
      raw = %{since: 1.0e9, until: 1.0e10}
      filter = Nostr.Filter.parse(raw)

      assert filter.since == ~U[2001-09-09 01:46:40Z]
      assert %DateTime{} = filter.until
    end

    test "parses filter with tag filters" do
      raw = %{
        "#e": ["event1", "event2"],
        "#p": ["pubkey1"]
      }

      filter = Nostr.Filter.parse(raw)
      assert filter."#e" == ["event1", "event2"]
      assert filter."#p" == ["pubkey1"]
    end

    test "parses filter with arbitrary single-letter tag filters (NIP-01)" do
      raw = %{
        "#t" => ["nostr", "bitcoin"],
        "#g" => ["u4pruydqqvj"],
        "#r" => ["https://example.com"]
      }

      filter = Nostr.Filter.parse(raw)

      assert filter.tags == %{
               "#t" => ["nostr", "bitcoin"],
               "#g" => ["u4pruydqqvj"],
               "#r" => ["https://example.com"]
             }
    end

    test "parses filter with mixed known and arbitrary tags" do
      raw = %{
        "kinds" => [1],
        "#e" => ["event1"],
        "#t" => ["tag1"]
      }

      filter = Nostr.Filter.parse(raw)
      assert filter.kinds == [1]
      assert filter."#e" == ["event1"]
      assert filter.tags == %{"#t" => ["tag1"]}
    end

    test "ignores multi-letter tag keys" do
      raw = %{"#tag" => ["value"], "kinds" => [1]}
      filter = Nostr.Filter.parse(raw)

      assert filter.kinds == [1]
      assert filter.tags == nil
    end
  end

  describe "JSON encoding" do
    test "encodes filter to JSON" do
      filter = %Nostr.Filter{
        kinds: [1, 2],
        limit: 10
      }

      json = JSON.encode!(filter)
      decoded = JSON.decode!(json)

      assert decoded["kinds"] == [1, 2]
      assert decoded["limit"] == 10
      refute Map.has_key?(decoded, "ids")
      refute Map.has_key?(decoded, "authors")
    end

    test "encodes timestamps as unix integers" do
      filter = %Nostr.Filter{
        since: ~U[2024-01-01 00:00:00Z],
        until: ~U[2024-01-02 00:00:00Z]
      }

      json = JSON.encode!(filter)
      decoded = JSON.decode!(json)

      assert decoded["since"] == 1_704_067_200
      assert decoded["until"] == 1_704_153_600
    end

    test "omits nil fields from JSON" do
      filter = %Nostr.Filter{kinds: [1]}
      json = JSON.encode!(filter)
      decoded = JSON.decode!(json)

      assert Map.keys(decoded) == ["kinds"]
    end

    test "encodes tag filters" do
      filter = %Nostr.Filter{
        "#e": ["event1"],
        "#p": ["pubkey1"]
      }

      json = JSON.encode!(filter)
      decoded = JSON.decode!(json)

      assert decoded["#e"] == ["event1"]
      assert decoded["#p"] == ["pubkey1"]
    end

    test "encodes arbitrary single-letter tag filters" do
      filter = %Nostr.Filter{
        kinds: [1],
        tags: %{"#t" => ["nostr"], "#g" => ["geohash"]}
      }

      json = JSON.encode!(filter)
      decoded = JSON.decode!(json)

      assert decoded["kinds"] == [1]
      assert decoded["#t"] == ["nostr"]
      assert decoded["#g"] == ["geohash"]
      refute Map.has_key?(decoded, "tags")
    end
  end

  describe "matches?/2" do
    test "empty filter matches any event" do
      event = Fixtures.signed_event()
      filter = %Nostr.Filter{}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "matches by kind" do
      event = Fixtures.signed_event(kind: 1)
      filter = %Nostr.Filter{kinds: [1, 7]}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "rejects non-matching kind" do
      event = Fixtures.signed_event(kind: 1)
      filter = %Nostr.Filter{kinds: [7, 30_023]}

      refute Nostr.Filter.matches?(filter, event)
    end

    test "matches by author (exact)" do
      event = Fixtures.signed_event()
      filter = %Nostr.Filter{authors: [Fixtures.pubkey()]}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "matches by author prefix" do
      event = Fixtures.signed_event()
      prefix = String.slice(Fixtures.pubkey(), 0, 8)
      filter = %Nostr.Filter{authors: [prefix]}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "rejects non-matching author" do
      event = Fixtures.signed_event()
      filter = %Nostr.Filter{authors: [Fixtures.pubkey2()]}

      refute Nostr.Filter.matches?(filter, event)
    end

    test "matches by id prefix" do
      event = Fixtures.signed_event()
      prefix = String.slice(event.id, 0, 8)
      filter = %Nostr.Filter{ids: [prefix]}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "rejects non-matching id" do
      event = Fixtures.signed_event()
      filter = %Nostr.Filter{ids: ["0000000000000000"]}

      refute Nostr.Filter.matches?(filter, event)
    end

    test "matches since constraint" do
      event = Fixtures.signed_event(created_at: ~U[2024-06-15 00:00:00Z])
      filter = %Nostr.Filter{since: ~U[2024-01-01 00:00:00Z]}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "matches since at exact boundary" do
      event = Fixtures.signed_event(created_at: ~U[2024-01-01 00:00:00Z])
      filter = %Nostr.Filter{since: ~U[2024-01-01 00:00:00Z]}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "rejects event before since" do
      event = Fixtures.signed_event(created_at: ~U[2023-06-01 00:00:00Z])
      filter = %Nostr.Filter{since: ~U[2024-01-01 00:00:00Z]}

      refute Nostr.Filter.matches?(filter, event)
    end

    test "matches until constraint" do
      event = Fixtures.signed_event(created_at: ~U[2024-01-01 00:00:00Z])
      filter = %Nostr.Filter{until: ~U[2024-06-01 00:00:00Z]}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "rejects event after until" do
      event = Fixtures.signed_event(created_at: ~U[2025-01-01 00:00:00Z])
      filter = %Nostr.Filter{until: ~U[2024-06-01 00:00:00Z]}

      refute Nostr.Filter.matches?(filter, event)
    end

    test "matches #e tag filter" do
      event = Fixtures.signed_event(tags: [Nostr.Tag.create(:e, "abc123")])
      filter = %Nostr.Filter{"#e": ["abc123", "def456"]}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "rejects when #e tag not present" do
      event = Fixtures.signed_event(tags: [])
      filter = %Nostr.Filter{"#e": ["abc123"]}

      refute Nostr.Filter.matches?(filter, event)
    end

    test "matches #p tag filter" do
      event = Fixtures.signed_event(tags: [Nostr.Tag.create(:p, Fixtures.pubkey2())])
      filter = %Nostr.Filter{"#p": [Fixtures.pubkey2()]}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "matches dynamic tag filter" do
      event = Fixtures.signed_event(tags: [Nostr.Tag.create(:t, "nostr")])
      filter = %Nostr.Filter{tags: %{"#t" => ["nostr", "bitcoin"]}}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "rejects non-matching dynamic tag" do
      event = Fixtures.signed_event(tags: [Nostr.Tag.create(:t, "elixir")])
      filter = %Nostr.Filter{tags: %{"#t" => ["nostr", "bitcoin"]}}

      refute Nostr.Filter.matches?(filter, event)
    end

    test "AND semantics — all fields must match" do
      event = Fixtures.signed_event(kind: 1)
      filter = %Nostr.Filter{kinds: [1], authors: [Fixtures.pubkey2()]}

      refute Nostr.Filter.matches?(filter, event)
    end

    test "AND semantics — both fields match" do
      event = Fixtures.signed_event(kind: 1)
      filter = %Nostr.Filter{kinds: [1], authors: [Fixtures.pubkey()]}

      assert Nostr.Filter.matches?(filter, event)
    end
  end

  describe "search matching (NIP-50)" do
    test "matches when content contains search term" do
      event = Fixtures.signed_event(content: "the best nostr apps for beginners")
      filter = %Nostr.Filter{search: "nostr"}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "does not match when content lacks search term" do
      event = Fixtures.signed_event(content: "hello world")
      filter = %Nostr.Filter{search: "nostr"}

      refute Nostr.Filter.matches?(filter, event)
    end

    test "nil search always matches" do
      event = Fixtures.signed_event(content: "anything")
      filter = %Nostr.Filter{search: nil}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "empty search always matches" do
      event = Fixtures.signed_event(content: "anything")
      filter = %Nostr.Filter{search: ""}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "case insensitive matching" do
      event = Fixtures.signed_event(content: "NOSTR is Great")
      filter = %Nostr.Filter{search: "nostr great"}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "multi-term AND semantics" do
      event = Fixtures.signed_event(content: "nostr apps are the best")

      assert Nostr.Filter.matches?(%Nostr.Filter{search: "nostr best"}, event)
      refute Nostr.Filter.matches?(%Nostr.Filter{search: "nostr missing"}, event)
    end

    test "extension tokens are ignored" do
      event = Fixtures.signed_event(content: "nostr is great")
      filter = %Nostr.Filter{search: "nostr language:en"}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "only extension tokens matches everything" do
      event = Fixtures.signed_event(content: "anything")
      filter = %Nostr.Filter{search: "language:en domain:example.com"}

      assert Nostr.Filter.matches?(filter, event)
    end

    test "search combined with other filter fields" do
      event = Fixtures.signed_event(kind: 1, content: "nostr is awesome")

      assert Nostr.Filter.matches?(%Nostr.Filter{search: "nostr", kinds: [1]}, event)
      refute Nostr.Filter.matches?(%Nostr.Filter{search: "nostr", kinds: [7]}, event)
      refute Nostr.Filter.matches?(%Nostr.Filter{search: "missing", kinds: [1]}, event)
    end
  end

  describe "any_match?/2" do
    test "returns true when any filter matches (OR semantics)" do
      event = Fixtures.signed_event(kind: 1)

      filters = [
        %Nostr.Filter{kinds: [7]},
        %Nostr.Filter{kinds: [1]}
      ]

      assert Nostr.Filter.any_match?(filters, event)
    end

    test "returns false when no filter matches" do
      event = Fixtures.signed_event(kind: 1)

      filters = [
        %Nostr.Filter{kinds: [7]},
        %Nostr.Filter{kinds: [30_023]}
      ]

      refute Nostr.Filter.any_match?(filters, event)
    end

    test "empty filter list returns false" do
      event = Fixtures.signed_event()

      refute Nostr.Filter.any_match?([], event)
    end
  end

  describe "roundtrip" do
    test "parse and encode arbitrary tags" do
      raw = %{"kinds" => [1], "#t" => ["nostr"], "#r" => ["url"]}
      filter = Nostr.Filter.parse(raw)
      json = JSON.encode!(filter)
      decoded = JSON.decode!(json)

      assert decoded["kinds"] == [1]
      assert decoded["#t"] == ["nostr"]
      assert decoded["#r"] == ["url"]
    end
  end
end
