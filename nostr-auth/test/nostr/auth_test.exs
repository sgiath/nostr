defmodule Nostr.AuthTest do
  use ExUnit.Case, async: true

  alias Nostr.Auth
  alias Nostr.Event
  alias Nostr.Event.HttpAuth

  @seckey String.duplicate("1", 64)
  @now ~U[2024-01-01 00:00:00Z]

  defmodule ReplayAccept do
    @behaviour Nostr.Auth.ReplayCache

    @impl true
    def check_and_store(_event, _opts), do: :ok
  end

  defmodule ReplayReject do
    @behaviour Nostr.Auth.ReplayCache

    @impl true
    def check_and_store(_event, _opts), do: {:error, :replayed}
  end

  describe "extract_authorization_header/1" do
    test "extracts from map and list headers" do
      map_headers = %{"authorization" => "Nostr token"}
      list_headers = [{"content-type", "application/json"}, {"authorization", "Nostr token"}]

      assert {:ok, "Nostr token"} = Auth.extract_authorization_header(map_headers)
      assert {:ok, "Nostr token"} = Auth.extract_authorization_header(list_headers)
    end
  end

  describe "decode_authorization_header/1" do
    test "returns invalid scheme error" do
      assert {:error, :invalid_authorization_scheme} =
               Auth.decode_authorization_header("Bearer abc")
    end
  end

  describe "validate_authorization_header/3" do
    test "validates a signed NIP-98 header" do
      url = "https://api.example.com/v1/users?limit=10"
      header = header_for(url, "GET", created_at: @now)
      request_context = %{url: url, method: "GET"}

      assert {:ok, %Event{kind: 27_235}} =
               Auth.validate_authorization_header(header, request_context,
                 nip98: [now: @now],
                 replay: {ReplayAccept, []}
               )
    end

    test "returns NIP-98 mismatch errors" do
      header = header_for("https://api.example.com/v1/users?limit=10", "GET", created_at: @now)
      request_context = %{url: "https://api.example.com/v1/users?limit=20", method: "GET"}

      assert {:error, {:nip98, {:url_mismatch, _, _}}} =
               Auth.validate_authorization_header(header, request_context, nip98: [now: @now])
    end

    test "returns replay errors from adapter" do
      url = "https://api.example.com/v1/users"
      header = header_for(url, "GET", created_at: @now)
      request_context = %{url: url, method: "GET"}

      assert {:error, {:replay, :replayed}} =
               Auth.validate_authorization_header(header, request_context,
                 nip98: [now: @now],
                 replay: {ReplayReject, []}
               )
    end
  end

  describe "validate_event/3" do
    test "supports payload validation with precomputed hash" do
      url = "https://api.example.com/v1/admin"
      body = ~s({"method":"banpubkey"})

      header =
        header_for(url, "POST",
          created_at: @now,
          payload_hash: Nostr.NIP98.payload_hash(body)
        )

      {:ok, event} = Auth.parse_authorization_header(header)

      assert {:ok, %Event{}} =
               Auth.validate_event(event, %{url: url, method: "POST", body: body},
                 nip98: [now: @now, payload_policy: :require]
               )
    end
  end

  defp header_for(url, method, opts) do
    auth = HttpAuth.create(url, method, opts)
    signed = Event.sign(auth, @seckey)

    token =
      signed.event
      |> JSON.encode!()
      |> Base.encode64()

    "Nostr " <> token
  end
end
