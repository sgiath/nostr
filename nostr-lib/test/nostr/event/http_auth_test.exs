defmodule Nostr.Event.HttpAuthTest do
  use ExUnit.Case, async: true

  alias Nostr.Event
  alias Nostr.Event.HttpAuth
  alias Nostr.Tag
  alias Nostr.Test.Fixtures

  describe "create/3" do
    test "creates HTTP auth event with required tags" do
      auth = HttpAuth.create("https://api.example.com/v1/users?limit=10", "GET")

      assert %HttpAuth{} = auth
      assert auth.event.kind == 27_235
      assert auth.url == "https://api.example.com/v1/users?limit=10"
      assert auth.method == "GET"
      assert auth.payload == nil

      assert Enum.any?(auth.event.tags, &(&1.type == :u && &1.data == auth.url))
      assert Enum.any?(auth.event.tags, &(&1.type == :method && &1.data == "GET"))
    end

    test "creates payload tag from raw body" do
      payload = "hello world"
      auth = HttpAuth.create("https://api.example.com/v1/files", "POST", payload: payload)

      expected_hash =
        :sha256
        |> :crypto.hash(payload)
        |> Base.encode16(case: :lower)

      assert auth.payload == expected_hash

      payload_tag = Enum.find(auth.event.tags, &(&1.type == :payload))
      assert payload_tag.data == auth.payload
    end

    test "uses provided payload hash when present" do
      hash = String.duplicate("a", 64)
      auth = HttpAuth.create("https://api.example.com/v1/files", "POST", payload_hash: hash)

      assert auth.payload == hash

      payload_tag = Enum.find(auth.event.tags, &(&1.type == :payload))
      assert payload_tag.data == hash
    end
  end

  describe "parse/1" do
    test "parses valid HTTP auth event" do
      tags = [Tag.create(:u, "https://api.example.com/endpoint"), Tag.create(:method, "PATCH")]
      event = Event.create(27_235, tags: tags, content: "")

      parsed = HttpAuth.parse(event)

      assert %HttpAuth{} = parsed
      assert parsed.url == "https://api.example.com/endpoint"
      assert parsed.method == "PATCH"
      assert parsed.payload == nil
    end

    test "returns error when u tag is missing" do
      tags = [Tag.create(:method, "GET")]
      event = Event.create(27_235, tags: tags)

      assert {:error, "HTTP auth event must have exactly one u tag", ^event} =
               HttpAuth.parse(event)
    end

    test "returns error when method tags are duplicated" do
      tags = [
        Tag.create(:u, "https://api.example.com/endpoint"),
        Tag.create(:method, "GET"),
        Tag.create(:method, "POST")
      ]

      event = Event.create(27_235, tags: tags)

      assert {:error, "HTTP auth event must not contain multiple method tags", ^event} =
               HttpAuth.parse(event)
    end

    test "returns error for wrong kind" do
      event = Event.create(1, tags: [])

      assert {:error, "Event is not an HTTP auth event (expected kind 27235)", ^event} =
               HttpAuth.parse(event)
    end
  end

  describe "parser integration" do
    test "parse_specific routes kind 27235 to HttpAuth" do
      auth = HttpAuth.create("https://api.example.com/protected", "GET")
      signed = Event.sign(auth, Fixtures.seckey())

      raw =
        signed.event
        |> JSON.encode!()
        |> JSON.decode!()

      parsed = Event.parse_specific(raw)

      assert %HttpAuth{} = parsed
      assert parsed.url == "https://api.example.com/protected"
      assert parsed.method == "GET"
    end
  end
end
