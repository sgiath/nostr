defmodule Nostr.Relay.Web.SocketHandlerTest do
  use ExUnit.Case, async: true

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Message
  alias Nostr.Relay.Web.ConnectionState
  alias Nostr.Relay.Web.SocketHandler

  describe "lifecycle callbacks" do
    test "initializes state" do
      assert {:ok, %ConnectionState{}} = SocketHandler.init(%{})
    end

    test "stores req subscriptions and sends eose" do
      {:ok, state} = SocketHandler.init(%{})

      request =
        %Filter{}
        |> Message.request("subscription-1")
        |> Message.serialize()

      expected =
        "subscription-1"
        |> Message.eose()
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %{messages: 1, subscriptions: subscriptions}
             } = SocketHandler.handle_in({request, opcode: :text}, state)

      assert MapSet.member?(subscriptions, "subscription-1")
    end

    test "removes subscription on CLOSE" do
      {:ok, state} = SocketHandler.init(%{})

      request =
        %Filter{}
        |> Message.request("subscription-1")
        |> Message.serialize()

      {:push, [_frame], %{subscriptions: subscriptions} = state_after_req} =
        SocketHandler.handle_in({request, opcode: :text}, state)

      assert MapSet.member?(subscriptions, "subscription-1")

      close = Message.close("subscription-1") |> Message.serialize()

      assert {
               :ok,
               %{messages: 2, subscriptions: final_subscriptions}
             } = SocketHandler.handle_in({close, opcode: :text}, state_after_req)

      refute MapSet.member?(final_subscriptions, "subscription-1")
    end

    test "returns notice for invalid json" do
      {:ok, state} = SocketHandler.init(%{})

      expected =
        Message.notice("invalid message format")
        |> Message.serialize()

      assert {:push, [{:text, ^expected}], %ConnectionState{messages: 1} = new_state} =
               SocketHandler.handle_in({"{bad json", opcode: :text}, state)

      assert new_state == state |> ConnectionState.inc_messages()
    end

    test "keeps connection state across message sequence" do
      {:ok, state} = SocketHandler.init(%{})

      req =
        %Filter{}
        |> Message.request("sub-seq")
        |> Message.serialize()

      {:push, [{_frame, _}], state_after_req} =
        SocketHandler.handle_in({req, opcode: :text}, state)

      close = Message.close("sub-seq") |> Message.serialize()

      assert {:ok, %{messages: final_count, subscriptions: subscriptions}} =
               SocketHandler.handle_in({close, opcode: :text}, state_after_req)

      assert final_count == 2
      refute MapSet.member?(subscriptions, "sub-seq")
    end

    test "ignores binary frames" do
      {:ok, state} = SocketHandler.init(%{})

      assert {:ok, ^state} = SocketHandler.handle_in({<<1, 2, 3>>, opcode: :binary}, state)
    end

    test "stores other info messages unchanged" do
      {:ok, state} = SocketHandler.init(%{})

      assert {:ok, ^state} = SocketHandler.handle_info(:noop, state)
    end

    test "acknowledges valid event" do
      {:ok, state} = SocketHandler.init(%{})
      event = valid_signed_event()
      message = Message.create_event(event) |> Message.serialize()

      expected =
        event.id
        |> Message.ok(true, "event accepted")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %{messages: 1}
             } = SocketHandler.handle_in({message, opcode: :text}, state)
    end
  end

  defp valid_signed_event do
    seckey = "1111111111111111111111111111111111111111111111111111111111111111"

    1
    |> Event.create(content: "relay ack", created_at: ~U[2024-01-01 00:00:00Z])
    |> Event.sign(seckey)
  end
end
