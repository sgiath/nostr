defmodule Nostr.Relay.Web.MessageRouterTest do
  use ExUnit.Case, async: true

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Message
  alias Nostr.Relay.Web.ConnectionState
  alias Nostr.Relay.Web.MessageRouter

  describe "route_frame/2" do
    test "acks EVENT messages with OK and increments message count" do
      state = ConnectionState.new()
      event = valid_event()

      message =
        event
        |> Message.create_event()
        |> Message.serialize()

      expected =
        event.id
        |> Message.ok(true, "event accepted")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } =
               MessageRouter.route_frame(message, state)
    end

    test "subscribes on REQ and sends EOSE" do
      state = ConnectionState.new()

      request =
        %Filter{}
        |> Message.request("sub-1")
        |> Message.serialize()

      eose_payload =
        "sub-1"
        |> Message.eose()
        |> Message.serialize()

      assert {:push, [{:text, ^eose_payload}], routed_state} =
               MessageRouter.route_frame(request, state)

      assert routed_state.messages == 1
      assert ConnectionState.subscription_active?(routed_state, "sub-1")
    end

    test "closes subscriptions by idempotent removal" do
      state =
        ConnectionState.new()
        |> ConnectionState.add_subscription("sub-1")

      close =
        "sub-1"
        |> Message.close()
        |> Message.serialize()

      assert {:ok, routed_state} = MessageRouter.route_frame(close, state)

      assert routed_state.messages == 1
      refute ConnectionState.subscription_active?(routed_state, "sub-1")
    end

    test "removing a missing subscription still increments message count" do
      state = ConnectionState.new()

      close =
        "missing-sub"
        |> Message.close()
        |> Message.serialize()

      assert {:ok, routed_state} = MessageRouter.route_frame(close, state)
      assert routed_state.messages == 1
      refute ConnectionState.subscription_active?(routed_state, "missing-sub")
    end

    test "returns NOTICE for invalid payload" do
      state = ConnectionState.new()

      expected =
        "invalid message format"
        |> Message.notice()
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } = MessageRouter.route_frame("{bad json", state)
    end

    test "reopens and closes subscriptions independently per connection state" do
      request =
        %Filter{}
        |> Message.request("shared")
        |> Message.serialize()

      close =
        "shared"
        |> Message.close()
        |> Message.serialize()

      assert_task_results =
        Enum.map(1..2, fn _ ->
          Task.async(fn ->
            state = ConnectionState.new()

            {:push, [{:text, payload}], after_req} = MessageRouter.route_frame(request, state)

            assert payload ==
                     "shared"
                     |> Message.eose()
                     |> Message.serialize()

            {:ok, after_close} = MessageRouter.route_frame(close, after_req)

            {
              after_req.messages,
              after_close.messages,
              ConnectionState.subscription_count(after_close)
            }
          end)
        end)
        |> Task.await_many()

      assert assert_task_results == [{1, 2, 0}, {1, 2, 0}]
    end
  end

  defp valid_event do
    seckey = "1111111111111111111111111111111111111111111111111111111111111111"

    event =
      Event.create(
        1,
        content: "relay ack",
        created_at: ~U[2024-01-01 00:00:00Z]
      )

    Event.sign(event, seckey)
  end
end
