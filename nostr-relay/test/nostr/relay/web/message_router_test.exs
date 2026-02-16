defmodule Nostr.Relay.Web.MessageRouterTest do
  use Nostr.Relay.DataCase, async: false

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Message
  alias Nostr.Relay.Repo
  alias Nostr.Relay.Store
  alias Nostr.Relay.Store.Event, as: EventRecord
  alias Nostr.Relay.Web.ConnectionState
  alias Nostr.Relay.Web.MessageRouter
  alias Nostr.Tag

  @seckey "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  @author_one "1111111111111111111111111111111111111111111111111111111111111111"
  @author_two "2222222222222222222222222222222222222222222222222222222222222222"

  describe "route_frame/2" do
    setup do
      scope = make_ref()
      state = ConnectionState.new(store_scope: scope)
      Store.clear(scope: scope)
      Store.clear(scope: :default)

      %{state: state, scope: scope}
    end

    test "acks EVENT messages with OK and increments message count", %{state: state, scope: scope} do
      event = valid_event()

      message =
        event
        |> Message.create_event()
        |> Message.serialize()

      expected =
        event.id
        |> Message.ok(true, "")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1, store_scope: ^scope}
             } =
               MessageRouter.route_frame(message, state)
    end

    test "stores event JSON in events table", %{state: state, scope: scope} do
      event = valid_event()

      payload =
        event
        |> Message.create_event()
        |> Message.serialize()

      assert {
               :push,
               [{:text, _}],
               %ConnectionState{messages: 1, store_scope: ^scope}
             } = MessageRouter.route_frame(payload, state)

      assert %EventRecord{event_id: stored_event_id, raw_json: stored_raw_json} =
               Repo.get_by(EventRecord, event_id: event.id)

      assert stored_event_id == event.id

      # raw_json stores just the event object, not the full wire message
      assert {:ok, decoded} = JSON.decode(stored_raw_json)
      assert decoded["id"] == event.id
      assert decoded["pubkey"] == event.pubkey
    end

    test "subscribes on REQ and sends EOSE when no events match", %{state: state} do
      request =
        %Filter{}
        |> Message.request("sub-empty")
        |> Message.serialize()

      eose_payload = Message.eose("sub-empty") |> Message.serialize()

      assert {
               :push,
               [{:text, ^eose_payload}],
               %{messages: 1, subscriptions: subscriptions}
             } = MessageRouter.route_frame(request, state)

      assert [%Filter{}] = subscriptions["sub-empty"]
    end

    test "returns EOSE for REQ after malformed raw EVENT payload", %{state: state} do
      event =
        valid_event(created_at: ~U[2099-01-01 00:00:00Z])

      event_payload =
        event
        |> Message.create_event()
        |> Message.serialize()

      assert {:push, [{:text, _}], state_after_event} =
               MessageRouter.route_frame(event_payload, state)

      request =
        %Filter{ids: ["non-matching-id"]}
        |> Message.request("sub-no-match")
        |> Message.serialize()

      eose_payload = Message.eose("sub-no-match") |> Message.serialize()

      assert {
               :push,
               [{:text, ^eose_payload}],
               %{messages: 2, subscriptions: subscriptions}
             } = MessageRouter.route_frame(request, state_after_event)

      assert [%Filter{}] = subscriptions["sub-no-match"]
    end

    test "replays matching events in reverse time order and then EOSE", %{
      state: state,
      scope: scope
    } do
      old_event =
        valid_event(
          created_at: ~U[2024-01-01 00:00:00Z],
          created_by: @author_one,
          kind: 1,
          tags: [Tag.create(:e, "event-tag")]
        )

      new_event =
        valid_event(
          created_at: ~U[2024-01-02 00:00:00Z],
          created_by: @author_two,
          kind: 1,
          tags: [Tag.create(:e, "event-tag")]
        )

      :ok = Store.insert_event(old_event, scope: scope)
      :ok = Store.insert_event(new_event, scope: scope)

      request =
        %Filter{tags: %{"#e" => ["event-tag"]}}
        |> Message.request("sub-replay")
        |> Message.serialize()

      expected_events = [
        event_frame(new_event, "sub-replay"),
        event_frame(old_event, "sub-replay"),
        eose_frame("sub-replay")
      ]

      assert {
               :push,
               ^expected_events,
               routed_state
             } = MessageRouter.route_frame(request, state)

      assert routed_state.messages == 1
      assert ConnectionState.subscription_active?(routed_state, "sub-replay")
      assert routed_state.store_scope == scope
    end

    test "collapses kind 41 channel metadata by root on REQ", %{state: state, scope: scope} do
      root_id = String.duplicate("a", 64)

      older =
        channel_metadata_event(
          root_id: root_id,
          created_at: ~U[2024-01-01 00:00:00Z],
          tags: [
            Tag.create(:e, String.duplicate("b", 64)),
            Tag.create(:e, root_id, ["wss://relay", "root"])
          ]
        )

      newer =
        channel_metadata_event(
          root_id: root_id,
          created_at: ~U[2024-01-02 00:00:00Z]
        )

      :ok = Store.insert_event(older, scope: scope)
      :ok = Store.insert_event(newer, scope: scope)

      request =
        %Filter{kinds: [41]}
        |> Message.request("sub-kind41")
        |> Message.serialize()

      expected_frames = [
        event_frame(newer, "sub-kind41"),
        eose_frame("sub-kind41")
      ]

      assert {
               :push,
               ^expected_frames,
               routed_state
             } = MessageRouter.route_frame(request, state)

      assert routed_state.store_scope == scope
    end

    test "collapses kind 41 channel metadata by root on COUNT", %{state: state, scope: scope} do
      root_id = String.duplicate("f", 64)

      older = channel_metadata_event(root_id: root_id, created_at: ~U[2024-01-01 00:00:00Z])
      newer = channel_metadata_event(root_id: root_id, created_at: ~U[2024-01-02 00:00:00Z])

      :ok = Store.insert_event(older, scope: scope)
      :ok = Store.insert_event(newer, scope: scope)

      request =
        Message.count(%Filter{kinds: [41]}, "count-kind41")
        |> Message.serialize()

      expected_count = Message.count(1, "count-kind41") |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected_count}],
               _routed_state
             } = MessageRouter.route_frame(request, state)
    end

    test "hides events deleted by NIP-09 kind-5 references", %{state: state, scope: scope} do
      kept =
        valid_event(
          created_at: ~U[2024-01-02 00:00:00Z],
          created_by: @author_one,
          kind: 1,
          tags: [Tag.create(:e, "other")]
        )

      deleted_target =
        valid_event(
          created_at: ~U[2024-01-01 00:00:00Z],
          created_by: @author_one,
          kind: 1
        )

      deletion =
        valid_event(
          created_at: ~U[2024-01-03 00:00:00Z],
          created_by: @author_one,
          kind: 5,
          tags: [Tag.create(:e, deleted_target.id)]
        )

      :ok = Store.insert_event(kept, scope: scope)
      :ok = Store.insert_event(deletion, scope: scope)

      request =
        %Filter{kinds: [1]}
        |> Message.request("sub-delete-read")
        |> Message.serialize()

      expected_events = [
        event_frame(kept, "sub-delete-read"),
        eose_frame("sub-delete-read")
      ]

      assert {
               :push,
               ^expected_events,
               routed_state
             } = MessageRouter.route_frame(request, state)

      assert routed_state.messages == 1
      assert routed_state.store_scope == scope
    end

    test "hides kind 1059 gift-wraps from unauthenticated REQ readers", %{
      state: state,
      scope: scope
    } do
      gift_for_author_one = gift_wrap_event(recipient: @author_one)
      :ok = Store.insert_event(gift_for_author_one, scope: scope)

      request =
        %Filter{kinds: [10_59]}
        |> Message.request("sub-gift-wrap-no-auth")
        |> Message.serialize()

      expected_eose = eose_frame("sub-gift-wrap-no-auth")

      assert {
               :push,
               [^expected_eose],
               routed_state
             } = MessageRouter.route_frame(request, state)

      assert routed_state.store_scope == scope
    end

    test "returns only matching recipient gift-wraps for authenticated REQ readers", %{
      state: state,
      scope: scope
    } do
      gift_for_author_one = gift_wrap_event(recipient: @author_one)
      gift_for_author_two = gift_wrap_event(recipient: @author_two)

      :ok = Store.insert_event(gift_for_author_one, scope: scope)
      :ok = Store.insert_event(gift_for_author_two, scope: scope)

      authenticated_state = ConnectionState.authenticate_pubkey(state, @author_one)

      request =
        %Filter{kinds: [10_59]}
        |> Message.request("sub-gift-wrap-auth")
        |> Message.serialize()

      expected_events = [
        event_frame(gift_for_author_one, "sub-gift-wrap-auth"),
        eose_frame("sub-gift-wrap-auth")
      ]

      assert {
               :push,
               ^expected_events,
               routed_state
             } = MessageRouter.route_frame(request, authenticated_state)

      assert routed_state.store_scope == scope
    end

    test "counts gift-wraps by authenticated recipient only on COUNT", %{
      state: state,
      scope: scope
    } do
      gift_for_author_one = gift_wrap_event(recipient: @author_one)
      gift_for_author_two = gift_wrap_event(recipient: @author_two)

      :ok = Store.insert_event(gift_for_author_one, scope: scope)
      :ok = Store.insert_event(gift_for_author_two, scope: scope)

      count_request =
        Message.count(%Filter{kinds: [10_59]}, "count-gift-wraps")
        |> Message.serialize()

      expected_unauth_count = Message.count(0, "count-gift-wraps") |> Message.serialize()
      expected_auth_count = Message.count(1, "count-gift-wraps") |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected_unauth_count}],
               _auth_required_state
             } = MessageRouter.route_frame(count_request, state)

      authenticated_state = ConnectionState.authenticate_pubkey(state, @author_one)

      assert {
               :push,
               [{:text, ^expected_auth_count}],
               _authenticated_state
             } = MessageRouter.route_frame(count_request, authenticated_state)
    end

    test "hides kind 4 encrypted messages from unauthenticated REQ readers", %{
      state: state,
      scope: scope
    } do
      encrypted_for_author_one = encrypted_direct_message_event(recipient: @author_one)
      :ok = Store.insert_event(encrypted_for_author_one, scope: scope)

      request =
        %Filter{kinds: [4]}
        |> Message.request("sub-kind4-no-auth")
        |> Message.serialize()

      expected_eose = eose_frame("sub-kind4-no-auth")

      assert {
               :push,
               [^expected_eose],
               routed_state
             } = MessageRouter.route_frame(request, state)

      assert routed_state.store_scope == scope
    end

    test "returns only matching recipient kind 4 events for authenticated REQ readers", %{
      state: state,
      scope: scope
    } do
      encrypted_for_author_one = encrypted_direct_message_event(recipient: @author_one)
      encrypted_for_author_two = encrypted_direct_message_event(recipient: @author_two)

      :ok = Store.insert_event(encrypted_for_author_one, scope: scope)
      :ok = Store.insert_event(encrypted_for_author_two, scope: scope)

      authenticated_state = ConnectionState.authenticate_pubkey(state, @author_one)

      request =
        %Filter{kinds: [4]}
        |> Message.request("sub-kind4-auth")
        |> Message.serialize()

      expected_events = [
        event_frame(encrypted_for_author_one, "sub-kind4-auth"),
        eose_frame("sub-kind4-auth")
      ]

      assert {
               :push,
               ^expected_events,
               routed_state
             } = MessageRouter.route_frame(request, authenticated_state)

      assert routed_state.store_scope == scope
    end

    test "counts kind 4 encrypted messages by authenticated recipient only on COUNT", %{
      state: state,
      scope: scope
    } do
      encrypted_for_author_one = encrypted_direct_message_event(recipient: @author_one)
      encrypted_for_author_two = encrypted_direct_message_event(recipient: @author_two)

      :ok =
        Store.insert_event(encrypted_for_author_one, scope: scope)

      :ok =
        Store.insert_event(encrypted_for_author_two, scope: scope)

      count_request =
        Message.count(%Filter{kinds: [4]}, "count-kind4")
        |> Message.serialize()

      expected_unauth_count = Message.count(0, "count-kind4") |> Message.serialize()
      expected_auth_count = Message.count(1, "count-kind4") |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected_unauth_count}],
               _auth_required_state
             } = MessageRouter.route_frame(count_request, state)

      authenticated_state = ConnectionState.authenticate_pubkey(state, @author_one)

      assert {
               :push,
               [{:text, ^expected_auth_count}],
               _authenticated_state
             } = MessageRouter.route_frame(count_request, authenticated_state)
    end

    test "stores and serves kind 1059 gift-wraps with multiple recipients", %{
      state: state,
      scope: scope
    } do
      gift_for_both =
        gift_wrap_event(
          recipients: [@author_one, @author_two],
          created_at: ~U[2024-01-01 12:00:00Z]
        )

      payload = Message.create_event(gift_for_both) |> Message.serialize()
      expected_ok = Message.ok(gift_for_both.id, true, "") |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected_ok}],
               %ConnectionState{messages: 1, store_scope: ^scope}
             } = MessageRouter.route_frame(payload, state)

      recipient_one_state = ConnectionState.authenticate_pubkey(state, @author_one)
      recipient_two_state = ConnectionState.authenticate_pubkey(state, @author_two)

      both_recipients_state =
        state
        |> ConnectionState.authenticate_pubkey(@author_one)
        |> ConnectionState.authenticate_pubkey(@author_two)

      request =
        %Filter{ids: [gift_for_both.id]}
        |> Message.request("sub-gift-wrap-multi")
        |> Message.serialize()

      expected_frames = [
        event_frame(gift_for_both, "sub-gift-wrap-multi"),
        eose_frame("sub-gift-wrap-multi")
      ]

      assert {
               :push,
               ^expected_frames,
               routed_one
             } = MessageRouter.route_frame(request, recipient_one_state)

      assert routed_one.store_scope == scope

      assert {
               :push,
               ^expected_frames,
               routed_two
             } = MessageRouter.route_frame(request, recipient_two_state)

      assert routed_two.store_scope == scope

      assert {
               :push,
               ^expected_frames,
               _routed_both
             } = MessageRouter.route_frame(request, both_recipients_state)
    end

    test "rejects kind 1059 gift-wraps with no recipient p tags", %{state: state, scope: scope} do
      invalid_gift_wrap =
        Event.create(
          10_59,
          created_at: ~U[2024-01-01 12:00:00Z],
          tags: [Tag.create(:e, "not-a-recipient")],
          content: "gift wrapped"
        )
        |> Event.sign(@seckey)

      payload = Message.create_event(invalid_gift_wrap) |> Message.serialize()

      expected_error =
        Message.ok(
          invalid_gift_wrap.id,
          false,
          "rejected: gift-wrap requires at least one valid recipient p tag"
        )
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected_error}],
               %ConnectionState{messages: 1, store_scope: ^scope}
             } = MessageRouter.route_frame(payload, state)

      assert {:ok, []} = Store.query_events([%Filter{ids: [invalid_gift_wrap.id]}], scope: scope)
    end

    test "rejects kind 1059 gift-wraps with invalid recipient p tags", %{
      state: state,
      scope: scope
    } do
      invalid_gift_wrap =
        gift_wrap_event(
          created_at: ~U[2024-01-01 12:00:00Z],
          tags: [Tag.create(:p, "ZZZZ"), Tag.create(:p, "short")]
        )

      payload = Message.create_event(invalid_gift_wrap) |> Message.serialize()

      expected_error =
        Message.ok(
          invalid_gift_wrap.id,
          false,
          "rejected: gift-wrap requires at least one valid recipient p tag"
        )
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected_error}],
               %ConnectionState{messages: 1, store_scope: ^scope}
             } = MessageRouter.route_frame(payload, state)

      assert {:ok, []} = Store.query_events([%Filter{ids: [invalid_gift_wrap.id]}], scope: scope)
    end

    test "rejects kind 1059 gift-wraps when any recipient tag is malformed", %{
      state: state,
      scope: scope
    } do
      invalid_gift_wrap =
        gift_wrap_event(
          created_at: ~U[2024-01-01 12:00:00Z],
          tags: [Tag.create(:p, @author_one), Tag.create(:p, "not-a-recipient")]
        )

      payload = Message.create_event(invalid_gift_wrap) |> Message.serialize()

      expected_error =
        Message.ok(
          invalid_gift_wrap.id,
          false,
          "rejected: gift-wrap requires at least one valid recipient p tag"
        )
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected_error}],
               %ConnectionState{messages: 1, store_scope: ^scope}
             } = MessageRouter.route_frame(payload, state)

      assert {:ok, []} = Store.query_events([%Filter{ids: [invalid_gift_wrap.id]}], scope: scope)
    end

    test "enforces gift-wrap visibility with mixed ids and kinds on REQ", %{
      state: state,
      scope: scope
    } do
      normal = valid_event(created_at: ~U[2024-01-01 12:00:00Z], created_by: @author_one)

      gift_for_author_one =
        gift_wrap_event(recipient: @author_one, created_at: ~U[2024-01-02 12:00:00Z])

      gift_for_author_two =
        gift_wrap_event(recipient: @author_two, created_at: ~U[2024-01-03 12:00:00Z])

      :ok = Store.insert_event(normal, scope: scope)
      :ok = Store.insert_event(gift_for_author_one, scope: scope)
      :ok = Store.insert_event(gift_for_author_two, scope: scope)

      mixed_filter = %Filter{
        ids: [normal.id, gift_for_author_one.id, gift_for_author_two.id],
        kinds: [1, 10_59]
      }

      request = Message.request(mixed_filter, "sub-gift-wrap-mixed") |> Message.serialize()

      unauth_expected = [
        event_frame(normal, "sub-gift-wrap-mixed"),
        eose_frame("sub-gift-wrap-mixed")
      ]

      assert {
               :push,
               ^unauth_expected,
               _unauth_state
             } = MessageRouter.route_frame(request, state)

      authenticated_state = ConnectionState.authenticate_pubkey(state, @author_one)

      auth_expected = [
        event_frame(gift_for_author_one, "sub-gift-wrap-mixed"),
        event_frame(normal, "sub-gift-wrap-mixed"),
        eose_frame("sub-gift-wrap-mixed")
      ]

      assert {
               :push,
               ^auth_expected,
               _auth_state
             } = MessageRouter.route_frame(request, authenticated_state)
    end

    test "enforces gift-wrap visibility with mixed ids and kinds on COUNT", %{
      state: state,
      scope: scope
    } do
      normal = valid_event(created_at: ~U[2024-01-01 12:00:00Z], created_by: @author_one)

      gift_for_author_one =
        gift_wrap_event(recipient: @author_one, created_at: ~U[2024-01-02 12:00:00Z])

      gift_for_author_two =
        gift_wrap_event(recipient: @author_two, created_at: ~U[2024-01-03 12:00:00Z])

      :ok = Store.insert_event(normal, scope: scope)
      :ok = Store.insert_event(gift_for_author_one, scope: scope)
      :ok = Store.insert_event(gift_for_author_two, scope: scope)

      mixed_filter = %Filter{
        ids: [normal.id, gift_for_author_one.id, gift_for_author_two.id],
        kinds: [1, 10_59]
      }

      request = Message.count(mixed_filter, "count-gift-wrap-mixed") |> Message.serialize()

      expected_unauth = Message.count(1, "count-gift-wrap-mixed") |> Message.serialize()
      expected_auth = Message.count(2, "count-gift-wrap-mixed") |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected_unauth}],
               _unauth_state
             } = MessageRouter.route_frame(request, state)

      authenticated_state = ConnectionState.authenticate_pubkey(state, @author_one)

      assert {
               :push,
               [{:text, ^expected_auth}],
               _auth_state
             } = MessageRouter.route_frame(request, authenticated_state)
    end

    test "rejects regular events already deleted by kind-5 references", %{
      state: state,
      scope: scope
    } do
      deleted_target =
        valid_event(
          created_at: ~U[2024-01-01 00:00:00Z],
          created_by: @author_one,
          kind: 1
        )

      deletion =
        valid_event(
          created_at: ~U[2024-01-03 00:00:00Z],
          created_by: @author_one,
          kind: 5,
          tags: [Tag.create(:e, deleted_target.id)]
        )

      :ok = Store.insert_event(deletion, scope: scope)

      payload = Message.create_event(deleted_target) |> Message.serialize()

      expected_ok =
        Message.ok(deleted_target.id, false, "rejected: event is deleted")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected_ok}],
               %ConnectionState{messages: 1, store_scope: ^scope}
             } = MessageRouter.route_frame(payload, state)
    end

    test "rejects regular events already deleted by kind filters", %{
      state: state,
      scope: scope
    } do
      deleted_target =
        valid_event(
          created_at: ~U[2024-01-01 00:00:00Z],
          created_by: @author_one,
          kind: 1
        )

      deletion =
        valid_event(
          created_at: ~U[2024-01-03 00:00:00Z],
          created_by: @author_one,
          kind: 5,
          tags: [Tag.create(:e, deleted_target.id), Tag.create(:k, "1")]
        )

      :ok = Store.insert_event(deletion, scope: scope)

      payload = Message.create_event(deleted_target) |> Message.serialize()

      expected_ok =
        Message.ok(deleted_target.id, false, "rejected: event is deleted")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected_ok}],
               %ConnectionState{messages: 1, store_scope: ^scope}
             } = MessageRouter.route_frame(payload, state)
    end

    test "accepts regular events when deletion kind filter does not match", %{
      state: state,
      scope: scope
    } do
      deleted_target =
        valid_event(
          created_at: ~U[2024-01-01 00:00:00Z],
          created_by: @author_one,
          kind: 1
        )

      deletion =
        valid_event(
          created_at: ~U[2024-01-03 00:00:00Z],
          created_by: @author_one,
          kind: 5,
          tags: [Tag.create(:e, deleted_target.id), Tag.create(:k, "7")]
        )

      :ok = Store.insert_event(deletion, scope: scope)

      payload = Message.create_event(deleted_target) |> Message.serialize()

      expected_ok = Message.ok(deleted_target.id, true, "") |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected_ok}],
               %ConnectionState{messages: 1, store_scope: ^scope}
             } = MessageRouter.route_frame(payload, state)
    end

    test "rejects parameterized replaceable events already deleted by naddr", %{
      state: state,
      scope: scope
    } do
      deleted_target =
        valid_event(
          created_at: ~U[2024-01-01 00:00:00Z],
          created_by: @author_one,
          kind: 30_001,
          tags: [Tag.create(:d, "post-1")]
        )

      deletion =
        valid_event(
          created_at: ~U[2024-01-03 00:00:00Z],
          created_by: @author_one,
          kind: 5,
          tags: [
            Tag.create(:a, "30001:#{deleted_target.pubkey}:post-1"),
            Tag.create(:k, "30001")
          ]
        )

      :ok = Store.insert_event(deletion, scope: scope)

      payload = Message.create_event(deleted_target) |> Message.serialize()

      expected_ok =
        Message.ok(deleted_target.id, false, "rejected: event is deleted")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected_ok}],
               %ConnectionState{messages: 1, store_scope: ^scope}
             } = MessageRouter.route_frame(payload, state)
    end

    test "accepts kind-5 deletion from same pubkey on write", %{state: state, scope: scope} do
      deleted_target =
        valid_event(
          created_at: ~U[2024-01-01 00:00:00Z],
          created_by: @author_one,
          kind: 1
        )

      deletion =
        5
        |> Event.create(
          tags: [Tag.create(:e, deleted_target.id)],
          created_at: ~U[2024-01-03 00:00:00Z]
        )
        |> Event.sign(@author_one)

      :ok = Store.insert_event(deleted_target, scope: scope)

      payload = Message.create_event(deletion) |> Message.serialize()

      expected_ok = Message.ok(deletion.id, true, "") |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected_ok}],
               %ConnectionState{messages: 1, store_scope: ^scope}
             } = MessageRouter.route_frame(payload, state)

      assert {:ok, [stored]} = Store.query_events([%Filter{ids: [deletion.id]}], scope: scope)
      assert stored.id == deletion.id
    end

    test "rejects kind-5 deletion from different pubkey via e-tag", %{state: state, scope: scope} do
      deleted_target =
        valid_event(
          created_at: ~U[2024-01-01 00:00:00Z],
          created_by: @author_two,
          kind: 1
        )

      deletion =
        5
        |> Event.create(
          tags: [Tag.create(:e, deleted_target.id)],
          created_at: ~U[2024-01-03 00:00:00Z]
        )
        |> Event.sign(@author_one)

      :ok = Store.insert_event(deleted_target, scope: scope)

      payload = Message.create_event(deletion) |> Message.serialize()

      expected_ok =
        Message.ok(
          deletion.id,
          false,
          "rejected: deletion can only target events by same pubkey"
        )
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected_ok}],
               %ConnectionState{messages: 1, store_scope: ^scope}
             } = MessageRouter.route_frame(payload, state)

      assert {:ok, []} = Store.query_events([%Filter{ids: [deletion.id]}], scope: scope)
    end

    test "rejects kind-5 deletion when address pubkey mismatches", %{state: state, scope: scope} do
      deletion =
        5
        |> Event.create(
          tags: [Tag.create(:a, "1:#{@author_two}:address")],
          created_at: ~U[2024-01-03 00:00:00Z]
        )
        |> Event.sign(@author_one)

      payload = Message.create_event(deletion) |> Message.serialize()

      expected_ok =
        Message.ok(
          deletion.id,
          false,
          "rejected: deletion can only target events by same pubkey"
        )
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected_ok}],
               %ConnectionState{messages: 1, store_scope: ^scope}
             } = MessageRouter.route_frame(payload, state)

      assert {:ok, []} = Store.query_events([%Filter{ids: [deletion.id]}], scope: scope)
    end

    test "dispatches EVENT OK without inline fan-out (fan-out via PubSub)", %{state: state} do
      filter = %Filter{kinds: [1]}

      request =
        filter
        |> Message.request("live-sub")
        |> Message.serialize()

      {:push, [{:text, _eose}], active_state} = MessageRouter.route_frame(request, state)

      matching_event = valid_event(created_by: @author_one)
      event_payload = Message.create_event(matching_event) |> Message.serialize()

      ok_payload = Message.ok(matching_event.id, true, "") |> Message.serialize()

      assert {
               :push,
               [{:text, ^ok_payload}],
               %ConnectionState{messages: 2}
             } = MessageRouter.route_frame(event_payload, active_state)
    end

    test "does not dispatch EVENT to non-matching subscriptions", %{state: state} do
      filter = %Filter{kinds: [1]}

      request =
        filter
        |> Message.request("live-sub")
        |> Message.serialize()

      {:push, [{:text, _eose}], active_state} = MessageRouter.route_frame(request, state)

      non_matching_event = valid_event(created_by: @author_two, kind: 7)
      event_payload = Message.create_event(non_matching_event) |> Message.serialize()

      ok_payload =
        Message.ok(non_matching_event.id, true, "") |> Message.serialize()

      assert {
               :push,
               [{:text, ^ok_payload}],
               %ConnectionState{messages: 2}
             } = MessageRouter.route_frame(event_payload, active_state)
    end

    test "enforces filter fields ids/authors/tag criteria before returning events", %{
      state: state,
      scope: scope
    } do
      matching =
        valid_event(
          created_at: ~U[2024-01-01 00:00:00Z],
          created_by: @author_one,
          kind: 1,
          tags: [Tag.create(:p, "target-p")]
        )

      :ok = Store.insert_event(matching, scope: scope)

      non_matching =
        valid_event(
          created_at: ~U[2024-01-01 00:00:00Z],
          created_by: @author_two,
          kind: 2,
          tags: [Tag.create(:p, "other")]
        )

      :ok = Store.insert_event(non_matching, scope: scope)

      filter =
        %Filter{
          ids: [matching.id],
          authors: [matching.pubkey],
          kinds: [1]
        }
        |> Map.put(:"#p", ["target-p"])

      request =
        filter
        |> Message.request("sub-filter")
        |> Message.serialize()

      expected_frames = [
        event_frame(matching, "sub-filter"),
        eose_frame("sub-filter")
      ]

      assert {
               :push,
               ^expected_frames,
               routed_state
             } = MessageRouter.route_frame(request, state)

      assert routed_state.messages == 1
      assert routed_state.store_scope == scope
    end

    test "applies limit across matched results", %{state: state, scope: scope} do
      base = ~U[2024-01-01 00:00:00Z]

      for idx <- 0..2 do
        valid_event(created_at: DateTime.add(base, idx, :second), kind: 1)
        |> then(&Store.insert_event(&1, scope: scope))
      end

      request =
        %Filter{kinds: [1], limit: 2}
        |> Message.request("sub-limit")
        |> Message.serialize()

      assert {
               :push,
               event_frames,
               _routed_state
             } = MessageRouter.route_frame(request, state)

      assert length(event_frames) == 3
      assert List.last(event_frames) == eose_frame("sub-limit")

      event_ids =
        event_frames
        |> Enum.drop(-1)
        |> Enum.map(&extract_event_id/1)

      assert length(event_ids) == 2
    end

    test "closes subscriptions by idempotent removal" do
      state =
        ConnectionState.new()
        |> ConnectionState.add_subscription("sub-1")

      close = Message.close("sub-1") |> Message.serialize()

      assert {:ok, routed_state} = MessageRouter.route_frame(close, state)

      assert routed_state.messages == 1
      refute ConnectionState.subscription_active?(routed_state, "sub-1")
    end

    test "removing a missing subscription still increments message count" do
      state = ConnectionState.new()

      close =
        Message.close("missing-sub")
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

      close = Message.close("shared") |> Message.serialize()

      assert_task_results =
        Enum.map(1..2, fn _ ->
          Task.async(fn ->
            state = ConnectionState.new()

            {
              :push,
              [{:text, payload}],
              after_req
            } = MessageRouter.route_frame(request, state)

            assert payload == Message.serialize(Message.eose("shared"))

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

  defp extract_event_id({:text, payload}) do
    {:event, _sub_id, %Event{id: event_id}} = Message.parse(payload)

    event_id
  end

  defp event_frame(%Event{} = event, sub_id) when is_binary(sub_id) do
    {:text, Message.event(event, sub_id) |> Message.serialize()}
  end

  defp eose_frame(sub_id) when is_binary(sub_id) do
    {:text, Message.eose(sub_id) |> Message.serialize()}
  end

  defp valid_event do
    valid_event([])
  end

  defp valid_event(opts) when is_list(opts) do
    created_at = Keyword.get(opts, :created_at, ~U[2024-01-01 00:00:00Z])
    kind = Keyword.get(opts, :kind, 1)
    created_by = Keyword.get(opts, :created_by, @author_one)
    tags = Keyword.get(opts, :tags, [])

    Event.create(
      kind,
      created_at: created_at,
      tags: tags,
      content: "relay ack"
    )
    |> Event.sign(created_by)
  end

  defp gift_wrap_event(opts) when is_list(opts) do
    tags = Keyword.get(opts, :tags)

    recipients =
      Keyword.get(opts, :recipients, Keyword.get(opts, :recipient, @author_one))
      |> List.wrap()

    created_at = Keyword.get(opts, :created_at, ~U[2024-01-01 12:00:00Z])

    tags =
      case tags do
        nil -> Enum.map(recipients, &Tag.create(:p, &1))
        user_tags when is_list(user_tags) -> user_tags
      end

    Event.create(10_59,
      created_at: created_at,
      tags: tags,
      content: "gift wrapped"
    )
    |> Event.sign(@seckey)
  end

  defp channel_metadata_event(opts) when is_list(opts) do
    root_id = Keyword.get(opts, :root_id, String.duplicate("a", 64))
    created_at = Keyword.get(opts, :created_at, ~U[2024-01-01 12:00:00Z])

    tags =
      Keyword.get(opts, :tags, [
        Tag.create(:e, root_id, ["wss://relay", "root"]),
        Tag.create(:t, "chat")
      ])

    Event.create(41,
      created_at: created_at,
      tags: tags,
      content: "channel metadata"
    )
    |> Event.sign(@seckey)
  end

  defp encrypted_direct_message_event(opts) when is_list(opts) do
    tags = Keyword.get(opts, :tags)

    recipients =
      Keyword.get(opts, :recipients, Keyword.get(opts, :recipient, @author_one))
      |> List.wrap()

    created_at = Keyword.get(opts, :created_at, ~U[2024-01-01 12:00:00Z])

    tags =
      case tags do
        nil -> Enum.map(recipients, &Tag.create(:p, &1))
        user_tags when is_list(user_tags) -> user_tags
      end

    Event.create(4,
      created_at: created_at,
      tags: tags,
      content: "encrypted direct message"
    )
    |> Event.sign(@seckey)
  end
end
