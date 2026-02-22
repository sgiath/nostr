defmodule Nostr.Auth.PlugTest do
  use ExUnit.Case, async: true

  alias Nostr.Auth.Plug, as: AuthPlug
  alias Nostr.Event
  alias Nostr.Event.HttpAuth
  alias Plug.Conn
  alias Plug.Test

  @seckey String.duplicate("1", 64)
  @now ~U[2024-01-01 00:00:00Z]

  describe "request_url/1" do
    test "builds URL including query and non-default port" do
      conn =
        Test.conn("GET", "/v1/users?limit=10")
        |> put_conn_parts(:https, "api.example.com", 444)

      assert AuthPlug.request_url(conn) == "https://api.example.com:444/v1/users?limit=10"
    end
  end

  describe "request_context/2" do
    test "adds request body when provided" do
      conn =
        Test.conn("POST", "/v1/upload")
        |> put_conn_parts(:https, "api.example.com", 443)

      context = AuthPlug.request_context(conn, body: "abc")

      assert context.url == "https://api.example.com/v1/upload"
      assert context.method == "POST"
      assert context.body == "abc"
    end
  end

  describe "validate_conn/2" do
    test "validates a conn with NIP-98 header" do
      url = "https://api.example.com/v1/users?limit=10"

      conn =
        Test.conn("GET", "/v1/users?limit=10")
        |> put_conn_parts(:https, "api.example.com", 443)
        |> Conn.put_req_header("authorization", header_for(url, "GET", created_at: @now))

      assert {:ok, %Event{kind: 27_235}} = AuthPlug.validate_conn(conn, nip98: [now: @now])
    end

    test "returns missing header error" do
      conn =
        Test.conn("GET", "/v1/users")
        |> put_conn_parts(:https, "api.example.com", 443)

      assert {:error, :missing_authorization_header} = AuthPlug.validate_conn(conn)
    end

    test "validates payload with body option" do
      url = "https://api.example.com/v1/admin"
      body = ~s({"method":"allowpubkey"})

      conn =
        Test.conn("POST", "/v1/admin")
        |> put_conn_parts(:https, "api.example.com", 443)
        |> Conn.put_req_header(
          "authorization",
          header_for(url, "POST", created_at: @now, payload_hash: Nostr.NIP98.payload_hash(body))
        )

      assert {:ok, %Event{kind: 27_235}} =
               AuthPlug.validate_conn(conn,
                 body: body,
                 nip98: [now: @now, payload_policy: :require]
               )
    end
  end

  defp put_conn_parts(%Conn{} = conn, scheme, host, port) do
    %{conn | scheme: scheme, host: host, port: port}
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
