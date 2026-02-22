defmodule Nostr.Auth.Plug.RequireNip98Test do
  use ExUnit.Case, async: true

  alias Nostr.Auth.Plug.RequireNip98
  alias Nostr.Event
  alias Nostr.Event.HttpAuth
  alias Plug.Conn
  alias Plug.Test

  @seckey String.duplicate("1", 64)
  @now ~U[2024-01-01 00:00:00Z]

  describe "call/2" do
    test "assigns validated event" do
      url = "https://api.example.com/v1/users?limit=10"

      conn =
        Test.conn("GET", "/v1/users?limit=10")
        |> put_conn_parts(:https, "api.example.com", 443)
        |> Conn.put_req_header("authorization", header_for(url, "GET", created_at: @now))

      opts = RequireNip98.init(assign: :auth_event, nip98: [now: @now])
      conn = RequireNip98.call(conn, opts)

      assert %Event{kind: 27_235} = conn.assigns.auth_event
      refute conn.halted
    end

    test "halts with default 401 on missing header" do
      conn =
        Test.conn("GET", "/v1/users")
        |> put_conn_parts(:https, "api.example.com", 443)

      opts = RequireNip98.init([])
      conn = RequireNip98.call(conn, opts)

      assert conn.halted
      assert conn.status == 401
      assert conn.resp_body =~ "unauthorized"
    end

    test "supports custom error status" do
      conn =
        Test.conn("GET", "/v1/users")
        |> put_conn_parts(:https, "api.example.com", 443)

      opts = RequireNip98.init(error_status: 403)
      conn = RequireNip98.call(conn, opts)

      assert conn.halted
      assert conn.status == 403
    end

    test "supports custom on_error callback" do
      conn =
        Test.conn("GET", "/v1/users")
        |> put_conn_parts(:https, "api.example.com", 443)

      opts =
        RequireNip98.init(
          on_error: fn conn, reason ->
            conn
            |> Conn.put_resp_content_type("application/json")
            |> Conn.send_resp(401, ~s({"error":"#{inspect(reason)}"}))
            |> Conn.halt()
          end
        )

      conn = RequireNip98.call(conn, opts)

      assert conn.halted
      assert conn.status == 401
      assert conn.resp_body =~ "missing_authorization_header"
    end

    test "reads body and validates payload when required" do
      body = ~s({"method":"allowpubkey"})
      url = "https://api.example.com/v1/admin"

      conn =
        Test.conn("POST", "/v1/admin", body)
        |> put_conn_parts(:https, "api.example.com", 443)
        |> Conn.put_req_header(
          "authorization",
          header_for(url, "POST", created_at: @now, payload_hash: Nostr.NIP98.payload_hash(body))
        )

      opts =
        RequireNip98.init(
          read_body: true,
          body_assign: :raw_body,
          nip98: [now: @now, payload_policy: :require]
        )

      conn = RequireNip98.call(conn, opts)

      assert %Event{kind: 27_235} = conn.assigns.nostr_event
      assert conn.assigns.raw_body == body
      refute conn.halted
    end

    test "supports request_context callback" do
      url = "https://api.example.com/v1/users?limit=10"

      conn =
        Test.conn("GET", "/v1/users?limit=10")
        |> put_conn_parts(:https, "api.example.com", 443)
        |> Conn.put_req_header("authorization", header_for(url, "GET", created_at: @now))

      opts =
        RequireNip98.init(
          request_context: fn _conn ->
            %{url: url, method: "GET"}
          end,
          nip98: [now: @now]
        )

      conn = RequireNip98.call(conn, opts)

      assert %Event{kind: 27_235} = conn.assigns.nostr_event
      refute conn.halted
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
