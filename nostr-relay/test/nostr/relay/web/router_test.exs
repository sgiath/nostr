defmodule Nostr.Relay.Web.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias Nostr.Relay.Web.Router

  @moduletag :unit

  describe "GET /" do
    test "serves the relay landing page to HTTP clients" do
      conn = conn(:get, "/")
      response = Router.call(conn, Router.init([]))

      assert response.state == :sent
      assert response.status == 200

      content_type =
        response
        |> get_resp_header("content-type")
        |> Enum.at(0)

      assert content_type == "text/html; charset=utf-8"

      assert response.resp_body =~ "Nostr Relay"
      assert response.resp_body =~ "WebSocket relay is reachable at this endpoint"
    end

    test "upgrades websocket requests" do
      conn =
        conn(:get, "/")
        |> put_req_header("upgrade", "websocket")
        |> put_req_header("connection", "Upgrade")
        |> put_req_header("sec-websocket-key", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        |> put_req_header("sec-websocket-version", "13")

      response = Router.call(conn, Router.init([]))

      assert response.state == :upgraded
    end

    test "serves html when websocket handshake is incomplete" do
      conn =
        conn(:get, "/")
        |> put_req_header("upgrade", "websocket")
        |> put_req_header("connection", "Upgrade")

      response = Router.call(conn, Router.init([]))

      assert response.state == :sent
      assert response.status == 200

      content_type =
        response
        |> get_resp_header("content-type")
        |> Enum.at(0)

      assert content_type == "text/html; charset=utf-8"
    end
  end

  test "returns 404 for unknown route" do
    conn = conn(:get, "/not-found")
    response = Router.call(conn, Router.init([]))

    assert response.state == :sent
    assert response.status == 404
    assert response.resp_body == "not found"
  end
end
