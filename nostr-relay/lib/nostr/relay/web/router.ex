defmodule Nostr.Relay.Web.Router do
  @moduledoc """
  HTTP and WebSocket entrypoint for the relay.

  `/` is handled as follows:

  - If the request is a valid WebSocket upgrade request, we hand it to
    `Nostr.Relay.Web.SocketHandler` via `Conn.upgrade_adapter/3`.
  - If the request accepts `application/nostr+json`, we return the NIP-11 relay
    information document.
  - Otherwise, a lightweight landing page is served.

  The upgraded WebSocket handler receives per-connection state and callbacks
  through WebSock/ThousandIsland/Bandit, which means each accepted connection has its
  own process context.
  """
  use Plug.Router

  alias Plug.Conn
  alias Nostr.Relay.Web.ConnectionState
  alias Nostr.Relay.Web.Page
  alias Nostr.Relay.Web.RelayInfo
  alias Nostr.Relay.Web.SocketHandler

  plug(:match)
  plug(:dispatch)

  get "/" do
    if websocket_request?(conn) do
      websocket_upgrade(conn)
    else
      if metadata_request?(conn) do
        conn
        |> put_nip11_headers()
        |> send_resp(200, RelayInfo.json())
      else
        conn
        |> Conn.put_resp_content_type("text/html")
        |> send_resp(200, Page.html())
      end
    end
  end

  options "/" do
    conn
    |> put_nip11_headers()
    |> send_resp(204, "")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  @spec websocket_request?(Conn.t()) :: boolean()
  def websocket_request?(%Conn{} = conn) do
    conn.method == "GET" &&
      root_path?(conn) &&
      header_contains?(conn, "upgrade", "websocket") &&
      header_contains?(conn, "connection", "upgrade") &&
      header_present?(conn, "sec-websocket-key") &&
      header_present?(conn, "sec-websocket-version")
  end

  defp root_path?(%Conn{request_path: "/"}), do: true
  defp root_path?(_conn), do: false

  defp header_contains?(%Conn{} = conn, name, expected) do
    headers = Conn.get_req_header(conn, name)
    expected_value = String.downcase(expected)

    Enum.any?(headers, fn header ->
      header
      |> String.split(",", trim: true)
      |> Enum.any?(fn candidate ->
        String.downcase(String.trim(candidate)) == expected_value
      end)
    end)
  end

  defp header_present?(%Conn{} = conn, name),
    do: Conn.get_req_header(conn, name) != []

  defp metadata_request?(%Conn{} = conn) do
    Conn.get_req_header(conn, "accept")
    |> Enum.any?(fn header ->
      header
      |> String.split(",", trim: true)
      |> Enum.any?(fn candidate ->
        candidate
        |> String.trim()
        |> String.downcase()
        |> String.starts_with?("application/nostr+json")
      end)
    end)
  end

  defp websocket_upgrade(conn) do
    conn =
      case Conn.upgrade_adapter(conn, :websocket, {SocketHandler, ConnectionState.new(), []}) do
        upgraded_conn ->
          upgraded_conn
      end

    conn
  end

  defp put_nip11_headers(conn) do
    conn
    |> Conn.put_resp_content_type("application/nostr+json")
    |> Conn.put_resp_header("access-control-allow-origin", "*")
    |> Conn.put_resp_header("access-control-allow-headers", "*")
    |> Conn.put_resp_header("access-control-allow-methods", "GET, OPTIONS")
  end
end
