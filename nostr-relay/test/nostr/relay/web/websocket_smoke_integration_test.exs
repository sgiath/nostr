defmodule Nostr.Relay.Web.WebsocketSmokeIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Mint.HTTP
  alias Mint.WebSocket
  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Message
  alias Nostr.Relay.Web.Router

  @host "127.0.0.1"
  @scheme :http
  @scheme_ws :ws
  @path "/"

  describe "real websocket relay behavior" do
    setup do
      port = 40_000 + rem(System.unique_integer([:positive, :monotonic]), 3_000)

      bandit_opts = [
        ip: {127, 0, 0, 1},
        port: port,
        scheme: @scheme,
        plug: Router,
        websocket_options: [compress: false, max_frame_size: 8_000_000]
      ]

      start_supervised!({Bandit, bandit_opts})

      {:ok, port: port}
    end

    test "exchanges messages across two websocket connections", %{port: port} do
      left = open_socket!(port)
      right = open_socket!(port)

      on_exit(fn ->
        close_socket!(left)
        close_socket!(right)
      end)

      request =
        %Filter{}
        |> Message.request("shared")
        |> Message.serialize()

      expected_eose =
        "shared"
        |> Message.eose()
        |> Message.serialize()

      left = send_text!(left, request)
      assert recv_text!(left) == expected_eose

      right = send_text!(right, request)
      assert recv_text!(right) == expected_eose

      right = send_text!(right, "{bad")

      expected_invalid =
        "invalid message format"
        |> Message.notice()
        |> Message.serialize()

      assert recv_text!(right) == expected_invalid

      event = valid_event()
      event_message = Message.create_event(event) |> Message.serialize()
      left = send_text!(left, event_message)

      expected_ok =
        event.id
        |> Message.ok(true, "event accepted")
        |> Message.serialize()

      assert recv_text!(left) == expected_ok
    end
  end

  defp open_socket!(port) do
    {:ok, conn} = HTTP.connect(@scheme, @host, port, protocols: [:http1])
    {:ok, conn, request_ref} = WebSocket.upgrade(@scheme_ws, conn, @path, [])

    message = await_socket_message!("upgrade")

    {:ok, conn, responses} = WebSocket.stream(conn, message)

    assert Enum.any?(responses, fn
             {:status, captured_ref, 101} -> captured_ref == request_ref
             _ -> false
           end)

    assert Enum.any?(responses, fn
             {:headers, captured_ref, _} -> captured_ref == request_ref
             _ -> false
           end)

    headers =
      Enum.find_value(responses, fn
        {:headers, ^request_ref, response_headers} -> response_headers
        _ -> nil
      end)

    assert headers != nil

    {:ok, conn, websocket} = WebSocket.new(conn, request_ref, 101, headers)

    %{conn: conn, request_ref: request_ref, websocket: websocket}
  end

  defp send_text!(%{conn: conn, request_ref: request_ref, websocket: websocket} = state, payload)
       when is_binary(payload) do
    {:ok, websocket, encoded} = WebSocket.encode(websocket, {:text, payload})
    {:ok, conn} = WebSocket.stream_request_body(conn, request_ref, encoded)

    %{state | conn: conn, websocket: websocket}
  end

  defp recv_text!(%{conn: conn, request_ref: request_ref, websocket: websocket}) do
    state = %{conn: conn, request_ref: request_ref, websocket: websocket}
    recv_text_from_message(state, await_socket_message!("frame"))
  end

  defp recv_text_from_message(%{conn: conn, request_ref: request_ref} = state, message) do
    case WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}

        frame_data =
          Enum.find_value(responses, fn
            {:data, ^request_ref, data} -> data
            _ -> nil
          end)

        if is_nil(frame_data) do
          recv_text!(state)
        else
          {:ok, _websocket, frames} = WebSocket.decode(state.websocket, frame_data)

          text = extract_text_payload(frames)

          assert text != nil

          text
        end

      :unknown ->
        recv_text!(state)

      {:error, _conn, reason, _responses} ->
        flunk("websocket stream returned error: #{inspect(reason)}")
    end
  end

  defp close_socket!(%{conn: conn}) do
    HTTP.close(conn)
    :ok
  end

  defp await_socket_message!(label) do
    receive do
      message ->
        message
    after
      5_000 ->
        flunk("expected websocket #{label} message")
    end
  end

  defp extract_text_payload(frames) do
    Enum.find_value(frames, fn
      {:text, payload} -> payload
      _ -> nil
    end)
  end

  defp valid_event do
    seckey = "1111111111111111111111111111111111111111111111111111111111111111"

    Event.create(
      1,
      content: "relay ack",
      created_at: ~U[2024-01-01 00:00:00Z]
    )
    |> Event.sign(seckey)
  end
end
