defmodule Nostr.NIP98Test do
  use ExUnit.Case, async: true

  alias Nostr.Event
  alias Nostr.Event.HttpAuth
  alias Nostr.NIP98
  alias Nostr.Tag
  alias Nostr.Test.Fixtures

  @base_time ~U[2024-01-01 00:00:00Z]

  describe "payload_hash/1" do
    test "returns SHA256 hex" do
      assert NIP98.payload_hash("hello") ==
               "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    end
  end

  describe "validate_request/3" do
    test "validates matching kind, time, url, and method" do
      event =
        signed_http_auth_event("https://api.example.com/v1/users?limit=10", "GET", @base_time)

      request = %{url: "https://api.example.com/v1/users?limit=10", method: "GET"}

      assert :ok = NIP98.validate_request(event, request, now: @base_time, max_age_seconds: 60)
    end

    test "returns invalid_kind for non-27235 events" do
      event = Fixtures.signed_event(kind: 1, created_at: @base_time)
      request = %{url: "https://api.example.com/v1/users", method: "GET"}

      assert {:error, :invalid_kind} = NIP98.validate_request(event, request, now: @base_time)
    end

    test "returns created_at_too_old when outside max age" do
      event =
        signed_http_auth_event(
          "https://api.example.com/v1/users",
          "GET",
          ~U[2023-12-31 23:58:00Z]
        )

      request = %{url: "https://api.example.com/v1/users", method: "GET"}

      assert {:error, {:created_at_too_old, _now_unix, _event_unix}} =
               NIP98.validate_request(event, request, now: @base_time, max_age_seconds: 60)
    end

    test "returns created_at_too_new when event is in future" do
      event =
        signed_http_auth_event(
          "https://api.example.com/v1/users",
          "GET",
          ~U[2024-01-01 00:00:30Z]
        )

      request = %{url: "https://api.example.com/v1/users", method: "GET"}

      assert {:error, {:created_at_too_new, _now_unix, _event_unix}} =
               NIP98.validate_request(event, request, now: @base_time, max_future_seconds: 0)
    end

    test "returns url_mismatch when request URL differs" do
      event =
        signed_http_auth_event("https://api.example.com/v1/users?limit=10", "GET", @base_time)

      request = %{url: "https://api.example.com/v1/users?limit=20", method: "GET"}

      assert {:error, {:url_mismatch, "https://api.example.com/v1/users?limit=20", _actual}} =
               NIP98.validate_request(event, request, now: @base_time)
    end

    test "returns method_mismatch when request method differs" do
      event = signed_http_auth_event("https://api.example.com/v1/users", "POST", @base_time)
      request = %{url: "https://api.example.com/v1/users", method: "GET"}

      assert {:error, {:method_mismatch, "GET", "POST"}} =
               NIP98.validate_request(event, request, now: @base_time)
    end

    test "validates payload hash when payload tag is present" do
      body = ~s({"name":"nostr"})

      event =
        signed_http_auth_event("https://api.example.com/v1/users", "POST", @base_time,
          payload: body
        )

      request = %{url: "https://api.example.com/v1/users", method: "POST", body: body}

      assert :ok = NIP98.validate_request(event, request, now: @base_time)
    end

    test "returns payload_mismatch when payload hash does not match body" do
      event =
        signed_http_auth_event("https://api.example.com/v1/users", "POST", @base_time,
          payload: "expected"
        )

      request = %{url: "https://api.example.com/v1/users", method: "POST", body: "actual"}

      assert {:error, {:payload_mismatch, _expected, _actual}} =
               NIP98.validate_request(event, request, now: @base_time)
    end

    test "requires payload tag when payload_policy is require" do
      event = signed_http_auth_event("https://api.example.com/v1/users", "POST", @base_time)
      request = %{url: "https://api.example.com/v1/users", method: "POST", body: "{}"}

      assert {:error, :missing_payload_tag} =
               NIP98.validate_request(event, request,
                 now: @base_time,
                 payload_policy: :require
               )
    end

    test "ignores payload validation when payload_policy is ignore" do
      tags = [
        Tag.create(:u, "https://api.example.com/v1/users"),
        Tag.create(:method, "POST"),
        Tag.create(:payload, "not-a-sha")
      ]

      event = Fixtures.signed_event(kind: 27_235, tags: tags, created_at: @base_time)
      request = %{url: "https://api.example.com/v1/users", method: "POST"}

      assert :ok =
               NIP98.validate_request(event, request,
                 now: @base_time,
                 payload_policy: :ignore
               )
    end

    test "uses payload_hash override from request context" do
      body = "body-to-hash"

      event =
        signed_http_auth_event("https://api.example.com/v1/upload", "POST", @base_time,
          payload: body
        )

      request = %{
        url: "https://api.example.com/v1/upload",
        method: "POST",
        payload_hash: NIP98.payload_hash(body)
      }

      assert :ok = NIP98.validate_request(event, request, now: @base_time)
    end

    test "accepts HttpAuth struct input" do
      auth = HttpAuth.create("https://api.example.com/v1/users", "GET", created_at: @base_time)
      request = %{url: "https://api.example.com/v1/users", method: "GET"}

      assert :ok = NIP98.validate_request(auth, request, now: @base_time)
    end
  end

  defp signed_http_auth_event(url, method, created_at, opts \\ []) do
    auth = HttpAuth.create(url, method, Keyword.put(opts, :created_at, created_at))
    signed = Event.sign(auth, Fixtures.seckey())
    signed.event
  end
end
