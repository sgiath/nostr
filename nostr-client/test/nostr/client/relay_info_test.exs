defmodule Nostr.Client.RelayInfoTest do
  use ExUnit.Case, async: false

  alias Nostr.Client
  alias Nostr.Client.RelayInfo

  describe "fetch/2" do
    test "fetches relay info with accept header and preserved path/query" do
      Req.Test.stub(:relay_info_success, fn conn ->
        assert conn.request_path == "/relay"
        assert conn.query_string == "a=1"
        assert ["application/nostr+json"] == Plug.Conn.get_req_header(conn, "accept")

        body =
          JSON.encode!(%{
            "name" => "Example Relay",
            "supported_nips" => [1, 11, 42],
            "software" => "https://example.com/relay",
            "version" => "1.2.3",
            "limitation" => %{"max_limit" => 5000},
            "x_custom_field" => "custom"
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end)

      relay_url = "wss://relay.example/relay?a=1"

      assert {:ok, %RelayInfo{} = info} =
               RelayInfo.fetch(relay_url, plug: {Req.Test, :relay_info_success})

      assert info.name == "Example Relay"
      assert info.supported_nips == [1, 11, 42]
      assert info.software == "https://example.com/relay"
      assert info.version == "1.2.3"
      assert info.limitation == %{"max_limit" => 5000}
      assert info.extra == %{"x_custom_field" => "custom"}
      assert is_map(info.raw)
    end

    test "decodes binary JSON response body" do
      Req.Test.stub(:relay_info_binary, fn conn ->
        body = JSON.encode!(%{"name" => "Binary Relay", "tags" => ["sfw-only"]})

        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:ok, %RelayInfo{} = info} =
               RelayInfo.fetch("wss://relay.example", plug: {Req.Test, :relay_info_binary})

      assert info.name == "Binary Relay"
      assert info.tags == ["sfw-only"]
    end

    test "returns error for invalid relay URL" do
      assert {:error, :invalid_relay_url} = RelayInfo.fetch("https://relay.example")
    end

    test "returns error for non-200 responses" do
      Req.Test.stub(:relay_info_404, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, "{}")
      end)

      assert {:error, {:http_status, 404}} =
               RelayInfo.fetch("wss://relay.example", plug: {Req.Test, :relay_info_404})
    end

    test "returns error for invalid JSON" do
      Req.Test.stub(:relay_info_invalid_json, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, "not-json")
      end)

      assert {:error, :invalid_json} =
               RelayInfo.fetch("wss://relay.example", plug: {Req.Test, :relay_info_invalid_json})
    end

    test "returns error when request fails" do
      assert {:error, {:request_failed, _reason}} =
               RelayInfo.fetch("wss://relay.example", plug: {Req.Test, :missing_stub})
    end
  end

  describe "Nostr.Client.get_relay_info/2" do
    test "delegates to relay info fetcher" do
      Req.Test.stub(:relay_info_client, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, JSON.encode!(%{"name" => "Delegated Relay"}))
      end)

      assert {:ok, %RelayInfo{name: "Delegated Relay"}} =
               Client.get_relay_info("wss://relay.example", plug: {Req.Test, :relay_info_client})
    end
  end
end
