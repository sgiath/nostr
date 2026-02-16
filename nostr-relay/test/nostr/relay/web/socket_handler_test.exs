defmodule Nostr.Relay.Web.SocketHandlerTest do
  use Nostr.Relay.DataCase, async: false

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Message
  alias Nostr.Relay.Web.ConnectionState
  alias Nostr.Relay.Web.SocketHandler
  alias Nostr.Tag

  @seckey "1111111111111111111111111111111111111111111111111111111111111111"
  @author_one "1111111111111111111111111111111111111111111111111111111111111111"
  @author_two "2222222222222222222222222222222222222222222222222222222222222222"

  describe "lifecycle callbacks" do
    test "initializes state and sends AUTH challenge" do
      assert {:push, [{:text, auth_json}], %ConnectionState{} = state} =
               SocketHandler.init(%{})

      assert ["AUTH", challenge] = JSON.decode!(auth_json)
      assert is_binary(challenge)
      assert state.challenge == challenge
    end

    test "stores req subscriptions and sends eose" do
      state = init_state()

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

      assert [%Filter{}] = subscriptions["subscription-1"]
    end

    test "removes subscription on CLOSE" do
      state = init_state()

      request =
        %Filter{}
        |> Message.request("subscription-1")
        |> Message.serialize()

      {:push, [_frame], %{subscriptions: subscriptions} = state_after_req} =
        SocketHandler.handle_in({request, opcode: :text}, state)

      assert [%Filter{}] = subscriptions["subscription-1"]

      close = Message.close("subscription-1") |> Message.serialize()

      assert {
               :ok,
               %{messages: 2, subscriptions: final_subscriptions}
             } = SocketHandler.handle_in({close, opcode: :text}, state_after_req)

      refute is_map_key(final_subscriptions, "subscription-1")
    end

    test "returns notice for invalid json" do
      state = init_state()

      expected =
        Message.notice("invalid message format")
        |> Message.serialize()

      assert {:push, [{:text, ^expected}], %ConnectionState{messages: 1}} =
               SocketHandler.handle_in({"{bad json", opcode: :text}, state)
    end

    test "returns OK rejection for event with out-of-range created_at" do
      state = init_state()

      payload =
        ~s/["EVENT",{"id":"f17ba017ba0c0c16673b4bdbf63f2ca15e9f135c445d09f35f3675f7b7b5597d","pubkey":"be0e77e5ce9b00b7eb086f0e5e326900880636cf193fdb633877927f352d1f93","created_at":9223372036854775807,"kind":1,"sig":"aa885c9e4e59e6fc3c3c4a2aaaeb1708a00d464b43777a1a9c3fc097d8398db1c5dc84b9a8564591e062d63006412611eea66db113b3289b83b4732f906df7af","content":"","tags":[]}]/

      assert {:push, [{:text, ok_json}], %ConnectionState{messages: 1}} =
               SocketHandler.handle_in({payload, opcode: :text}, state)

      assert [
               "OK",
               "f17ba017ba0c0c16673b4bdbf63f2ca15e9f135c445d09f35f3675f7b7b5597d",
               false,
               "invalid: invalid created_at"
             ] = JSON.decode!(ok_json)
    end

    test "returns OK rejection for event with scientific notation created_at" do
      state = init_state()

      payload =
        ~s/["EVENT",{"id":"ba879483e2133f78fd55228455717169b61072feb7cfca2687d771dae24e0b2f","pubkey":"be0e77e5ce9b00b7eb086f0e5e326900880636cf193fdb633877927f352d1f93","created_at":1e+10,"kind":1,"tags":[],"content":"","sig":"e82967b0cc1ec3dd8fec43267f3b4944602f21ec1048ceb8e903a4d1aa83ed1d28aaf3a764bd29ce030d64613fd781e95ef1d0e2c9e10a943edb7b9b199fc4ee"}]/

      assert {:push, [{:text, ok_json}], %ConnectionState{messages: 1}} =
               SocketHandler.handle_in({payload, opcode: :text}, state)

      assert ["OK", _event_id, false, "invalid: invalid created_at"] = JSON.decode!(ok_json)
    end

    test "keeps connection state across message sequence" do
      state = init_state()

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
      refute is_map_key(subscriptions, "sub-seq")
    end

    test "ignores binary frames" do
      state = init_state()

      assert {:ok, ^state} = SocketHandler.handle_in({<<1, 2, 3>>, opcode: :binary}, state)
    end

    test "stores other info messages unchanged" do
      state = init_state()

      assert {:ok, ^state} = SocketHandler.handle_info(:noop, state)
    end

    test "acknowledges valid event" do
      state = init_state()
      event = valid_signed_event()
      message = Message.create_event(event) |> Message.serialize()

      expected =
        event.id
        |> Message.ok(true, "")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %{messages: 1}
             } = SocketHandler.handle_in({message, opcode: :text}, state)
    end
  end

  describe "fan-out via handle_info" do
    test "pushes event to matching subscription" do
      event = valid_signed_event()
      filter = %Filter{kinds: [1], authors: [event.pubkey]}
      state = ConnectionState.new() |> ConnectionState.add_subscription("sub-1", [filter])

      expected_frame =
        event
        |> Message.event("sub-1")
        |> Message.serialize()

      assert {:push, [{:text, ^expected_frame}], ^state} =
               SocketHandler.handle_info({:new_event, event}, state)
    end

    test "no-op when no subscriptions match" do
      event = valid_signed_event()
      filter = %Filter{kinds: [7]}
      state = ConnectionState.new() |> ConnectionState.add_subscription("sub-1", [filter])

      assert {:ok, ^state} = SocketHandler.handle_info({:new_event, event}, state)
    end

    test "no-op when no subscriptions exist" do
      event = valid_signed_event()
      state = ConnectionState.new()

      assert {:ok, ^state} = SocketHandler.handle_info({:new_event, event}, state)
    end

    test "pushes to multiple matching subscriptions" do
      event = valid_signed_event()
      filter_a = %Filter{kinds: [1]}
      filter_b = %Filter{authors: [event.pubkey]}

      state =
        ConnectionState.new()
        |> ConnectionState.add_subscription("sub-a", [filter_a])
        |> ConnectionState.add_subscription("sub-b", [filter_b])

      assert {:push, frames, ^state} =
               SocketHandler.handle_info({:new_event, event}, state)

      assert length(frames) == 2
    end

    test "only pushes to matching subscriptions, not all" do
      event = valid_signed_event()
      match_filter = %Filter{kinds: [1]}
      no_match_filter = %Filter{kinds: [7]}

      state =
        ConnectionState.new()
        |> ConnectionState.add_subscription("match", [match_filter])
        |> ConnectionState.add_subscription("no-match", [no_match_filter])

      assert {:push, [{:text, frame}], ^state} =
               SocketHandler.handle_info({:new_event, event}, state)

      assert frame =~ "match"
      refute frame =~ "no-match"
    end

    test "does not push private-message kinds to unauthenticated subscriptions" do
      for kind <- [4, 10_59] do
        event = private_message_event(kind, recipients: [@author_one])
        filter = %Filter{kinds: [kind], authors: [event.pubkey]}
        state = ConnectionState.new() |> ConnectionState.add_subscription("sub-1", [filter])

        assert {:ok, ^state} = SocketHandler.handle_info({:new_event, event}, state)
      end
    end

    test "pushes private-message kinds to authenticated recipients" do
      for kind <- [4, 10_59] do
        event = private_message_event(kind, recipients: [@author_one])
        filter = %Filter{kinds: [kind], authors: [event.pubkey]}

        state =
          ConnectionState.new()
          |> ConnectionState.authenticate_pubkey(@author_one)
          |> ConnectionState.add_subscription("sub-1", [filter])

        expected_frame =
          event
          |> Message.event("sub-1")
          |> Message.serialize()

        assert {:push, [{:text, ^expected_frame}], ^state} =
                 SocketHandler.handle_info({:new_event, event}, state)
      end
    end

    test "does not push private-message kinds to authenticated non-recipients" do
      for kind <- [4, 10_59] do
        event = private_message_event(kind, recipients: [@author_one])
        filter = %Filter{kinds: [kind], authors: [event.pubkey]}

        state =
          ConnectionState.new()
          |> ConnectionState.authenticate_pubkey(@author_two)
          |> ConnectionState.add_subscription("sub-1", [filter])

        assert {:ok, ^state} = SocketHandler.handle_info({:new_event, event}, state)
      end
    end

    test "pushes private-message kinds to any authenticated recipient in p tags" do
      for kind <- [4, 10_59] do
        event = private_message_event(kind, recipients: [@author_one, @author_two])
        filter = %Filter{kinds: [kind], authors: [event.pubkey]}

        state =
          ConnectionState.new()
          |> ConnectionState.authenticate_pubkey(@author_two)
          |> ConnectionState.add_subscription("sub-1", [filter])

        expected_frame =
          event
          |> Message.event("sub-1")
          |> Message.serialize()

        assert {:push, [{:text, ^expected_frame}], ^state} =
                 SocketHandler.handle_info({:new_event, event}, state)
      end
    end
  end

  defp init_state do
    {:push, _frames, state} = SocketHandler.init(%{})
    state
  end

  defp valid_signed_event do
    1
    |> Event.create(content: "relay ack", created_at: ~U[2024-01-01 00:00:00Z])
    |> Event.sign(@seckey)
  end

  defp private_message_event(kind, opts) when kind in [4, 10_59] and is_list(opts) do
    recipients = Keyword.get(opts, :recipients, [@author_one])
    created_at = Keyword.get(opts, :created_at, ~U[2024-01-01 00:00:00Z])

    tags = Enum.map(recipients, &Tag.create(:p, &1))

    kind
    |> Event.create(content: "private message", created_at: created_at, tags: tags)
    |> Event.sign(@seckey)
  end
end
