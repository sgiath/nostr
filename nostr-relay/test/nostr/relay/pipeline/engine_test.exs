defmodule Nostr.Relay.Pipeline.EngineTest do
  use Nostr.Relay.DataCase, async: false

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Message
  alias Nostr.Tag
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Engine
  alias Nostr.Relay.Pipeline.Stage
  alias Nostr.Relay.Repo
  alias Nostr.Relay.Store
  alias Nostr.Relay.Store.Event, as: EventRecord
  alias Nostr.Relay.Web.ConnectionState

  @seckey "1111111111111111111111111111111111111111111111111111111111111111"
  @seckey_b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  describe "Engine.run/3" do
    test "returns NOTICE for invalid JSON payloads" do
      state = ConnectionState.new()

      expected =
        Message.notice("invalid message format")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } = Engine.run("{bad json", state)
    end

    test "returns NOTICE when payload exceeds max_message_length" do
      original_relay_info = Application.get_env(:nostr_relay, :relay_info)

      on_exit(fn ->
        Application.put_env(:nostr_relay, :relay_info, original_relay_info)
      end)

      set_max_message_length(16)

      state = ConnectionState.new()
      payload = String.duplicate("a", 17)

      expected =
        Message.notice("message too large")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } = Engine.run(payload, state)
    end

    test "returns NOTICE for parseable unsupported messages" do
      state = ConnectionState.new()

      payload =
        Message.notice("noop")
        |> Message.serialize()

      expected =
        Message.notice("unsupported message type")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } = Engine.run(payload, state)
    end

    test "returns NOTICE for malformed JSON escapes" do
      state = ConnectionState.new()

      expected =
        Message.notice("invalid message: unsupported JSON escape")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } = Engine.run(~S(["EVENT","value\q"]), state)
    end

    test "returns NOTICE for unsupported JSON slash escape" do
      state = ConnectionState.new()

      expected =
        Message.notice("invalid message: unsupported JSON escape")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } = Engine.run(~S(["CLOSE","value\/"]), state)
    end

    test "returns NOTICE for unicode control escapes" do
      state = ConnectionState.new()

      expected =
        Message.notice("invalid message: unsupported JSON escape")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } = Engine.run(~S(["CLOSE","value\u0000"]), state)
    end

    test "returns NOTICE for unescaped control characters in JSON string" do
      state = ConnectionState.new()

      expected =
        Message.notice("invalid message: unsupported JSON literal control")
        |> Message.serialize()

      payload = "[\"CLOSE\",\"close" <> <<1>> <> "\"]"

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } = Engine.run(payload, state)
    end

    test "returns NOTICE when subscription id exceeds max_subid_length" do
      original_relay_info = Application.get_env(:nostr_relay, :relay_info)

      on_exit(fn ->
        Application.put_env(:nostr_relay, :relay_info, original_relay_info)
      end)

      relay_info = Application.get_env(:nostr_relay, :relay_info, [])
      limitation = Keyword.get(relay_info, :limitation, %{})

      Application.put_env(
        :nostr_relay,
        :relay_info,
        Keyword.put(relay_info, :limitation, Map.put(limitation, :max_subid_length, 3))
      )

      state = ConnectionState.new()

      payload =
        %Filter{}
        |> Message.request("sub-1")
        |> Message.serialize()

      expected =
        Message.notice("restricted: subscription id too long")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } = Engine.run(payload, state)
    end

    test "returns OK false when event content exceeds max_content_length" do
      original_relay_info = Application.get_env(:nostr_relay, :relay_info)

      on_exit(fn ->
        Application.put_env(:nostr_relay, :relay_info, original_relay_info)
      end)

      set_max_content_length(5)

      state = ConnectionState.new()
      event = valid_event(content: "hello!")

      payload =
        event
        |> Message.create_event()
        |> Message.serialize()

      event_id = event.id

      assert {:push, [{:text, ok_json}], %ConnectionState{messages: 1}} =
               Engine.run(payload, state)

      assert ["OK", ^event_id, false, "restricted: max content length exceeded"] =
               JSON.decode!(ok_json)
    end

    test "accepts valid EVENT messages through default stages" do
      state = ConnectionState.new()
      event = valid_event()

      payload =
        event
        |> Message.create_event()
        |> Message.serialize()

      expected =
        Message.ok(event.id, true, "")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } = Engine.run(payload, state)
    end

    test "returns OK false for stale replaceable events but keeps event storage" do
      state = ConnectionState.new()

      newer =
        0
        |> Event.create(content: "newest", created_at: ~U[2024-06-16 12:00:00Z])
        |> Event.sign(@seckey)

      older =
        0
        |> Event.create(content: "older", created_at: ~U[2024-06-15 12:00:00Z])
        |> Event.sign(@seckey)

      newer_payload = Message.create_event(newer) |> Message.serialize()
      older_payload = Message.create_event(older) |> Message.serialize()

      assert {
               :push,
               [{:text, new_ok_json}],
               state_after_newer
             } = Engine.run(newer_payload, state)

      assert ["OK", returned_newer_id, true, ""] = JSON.decode!(new_ok_json)
      assert returned_newer_id == newer.id

      assert {
               :push,
               [{:text, old_ok_json}],
               _state_after_older
             } = Engine.run(older_payload, state_after_newer)

      assert ["OK", returned_older_id, false, "rejected: stale replacement event"] =
               JSON.decode!(old_ok_json)

      assert returned_older_id == older.id

      assert {:ok, events} = Store.query_events([%Filter{kinds: [0]}], [])
      assert Enum.map(events, & &1.id) == [newer.id]

      stored_ids =
        from(record in EventRecord, where: record.kind == 0, select: record.event_id)
        |> Repo.all()
        |> Enum.sort()

      expected_ids =
        [newer.id, older.id]
        |> Enum.sort()

      assert stored_ids == expected_ids
    end

    test "returns OK false for stale parameterized replaceable events but keeps event storage" do
      state = ConnectionState.new()
      tag = Tag.create(:d, "profile-v1")

      newer =
        30_000
        |> Event.create(content: "newest", created_at: ~U[2024-06-16 12:00:00Z], tags: [tag])
        |> Event.sign(@seckey)

      older =
        30_000
        |> Event.create(content: "older", created_at: ~U[2024-06-15 12:00:00Z], tags: [tag])
        |> Event.sign(@seckey)

      newer_payload = Message.create_event(newer) |> Message.serialize()
      older_payload = Message.create_event(older) |> Message.serialize()

      assert {
               :push,
               [{:text, new_ok_json}],
               state_after_newer
             } = Engine.run(newer_payload, state)

      assert ["OK", returned_newer_id, true, ""] = JSON.decode!(new_ok_json)
      assert returned_newer_id == newer.id

      assert {
               :push,
               [{:text, old_ok_json}],
               _state_after_older
             } = Engine.run(older_payload, state_after_newer)

      assert ["OK", returned_older_id, false, "rejected: stale replacement event"] =
               JSON.decode!(old_ok_json)

      assert returned_older_id == older.id

      assert {:ok, events} = Store.query_events([%Filter{kinds: [30_000]}], [])
      assert Enum.map(events, & &1.id) == [newer.id]

      stored_ids =
        from(record in EventRecord, where: record.kind == 30_000, select: record.event_id)
        |> Repo.all()
        |> Enum.sort()

      expected_ids =
        [newer.id, older.id]
        |> Enum.sort()

      assert stored_ids == expected_ids
    end

    test "returns OK false when an already stored older replaceable event is retried" do
      state = ConnectionState.new()

      older =
        0
        |> Event.create(content: "older", created_at: ~U[2024-06-15 12:00:00Z])
        |> Event.sign(@seckey)

      newer =
        0
        |> Event.create(content: "newer", created_at: ~U[2024-06-16 12:00:00Z])
        |> Event.sign(@seckey)

      older_id = older.id
      newer_id = newer.id

      older_payload = Message.create_event(older) |> Message.serialize()
      newer_payload = Message.create_event(newer) |> Message.serialize()

      assert {
               :push,
               [{:text, first_old_ok_json}],
               state_after_first_old
             } = Engine.run(older_payload, state)

      assert ["OK", ^older_id, true, ""] = JSON.decode!(first_old_ok_json)

      assert {
               :push,
               [{:text, newer_ok_json}],
               state_after_newer
             } = Engine.run(newer_payload, state_after_first_old)

      assert ["OK", ^newer_id, true, ""] = JSON.decode!(newer_ok_json)

      assert {
               :push,
               [{:text, retried_old_ok_json}],
               _state_after_retried_old
             } = Engine.run(older_payload, state_after_newer)

      assert ["OK", ^older_id, false, "rejected: stale replacement event"] =
               JSON.decode!(retried_old_ok_json)

      assert {:ok, events} = Store.query_events([%Filter{kinds: [0]}], [])
      assert Enum.map(events, & &1.id) == [newer.id]
    end

    test "preserves duplicate: exact-id behavior for replaceable events" do
      state = ConnectionState.new()

      event =
        0
        |> Event.create(content: "stable", created_at: ~U[2024-06-16 12:00:00Z])
        |> Event.sign(@seckey)

      payload = Message.create_event(event) |> Message.serialize()

      assert {
               :push,
               [{:text, first_ok_json}],
               state_after_first
             } = Engine.run(payload, state)

      assert ["OK", returned_event_id, true, ""] = JSON.decode!(first_ok_json)
      assert returned_event_id == event.id

      assert {
               :push,
               [{:text, dup_ok_json}],
               _state_after_duplicate
             } = Engine.run(payload, state_after_first)

      event_id = event.id

      assert ["OK", ^event_id, true, "duplicate: already have this event"] =
               JSON.decode!(dup_ok_json)

      duplicate_count =
        from(record in EventRecord, where: record.event_id == ^event.id)
        |> Repo.aggregate(:count, :event_id)

      assert duplicate_count == 1
    end

    test "returns invalid pipeline result when a stage returns invalid output" do
      state = ConnectionState.new()

      expected =
        Message.notice("invalid pipeline result")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } = Engine.run("{}", state, stages: [__MODULE__.InvalidResultStage])
    end

    test "rejects deletion events that target another pubkey via e-tag" do
      state = ConnectionState.new()

      target =
        build_event(
          kind: 1,
          seckey: @seckey,
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      :ok = Store.insert_event(target, [])

      deletion =
        build_event(
          kind: 5,
          seckey: @seckey_b,
          created_at: ~U[2024-06-16 12:00:00Z],
          tags: [Tag.create(:e, target.id)]
        )

      payload = Message.create_event(deletion) |> Message.serialize()
      deletion_id = deletion.id

      assert {:push, [{:text, ok_json}], _state_after} = Engine.run(payload, state)

      assert [
               "OK",
               ^deletion_id,
               false,
               "rejected: deletion can only target events by same pubkey"
             ] = JSON.decode!(ok_json)

      assert {:ok, target_visible} = Store.query_events([%Filter{ids: [target.id]}], [])
      assert Enum.any?(target_visible, &(&1.id == target.id))

      assert {:ok, []} = Store.query_events([%Filter{ids: [deletion.id]}], [])
    end

    test "accepts deletion events that target own events via e-tag" do
      state = ConnectionState.new()

      target =
        build_event(
          kind: 1,
          seckey: @seckey,
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      :ok = Store.insert_event(target, [])

      deletion =
        build_event(
          kind: 5,
          seckey: @seckey,
          created_at: ~U[2024-06-16 12:00:00Z],
          tags: [Tag.create(:e, target.id)]
        )

      payload = Message.create_event(deletion) |> Message.serialize()
      deletion_id = deletion.id

      assert {:push, [{:text, ok_json}], _state_after} = Engine.run(payload, state)
      assert ["OK", ^deletion_id, true, ""] = JSON.decode!(ok_json)

      assert {:ok, []} = Store.query_events([%Filter{ids: [target.id]}], [])
      assert {:ok, inserted} = Store.query_events([%Filter{ids: [deletion.id]}], [])
      assert Enum.any?(inserted, &(&1.id == deletion.id))
    end

    test "rejects deletion events that target another pubkey via naddr" do
      state = ConnectionState.new()

      target =
        build_event(
          kind: 30_001,
          seckey: @seckey,
          created_at: ~U[2024-06-15 12:00:00Z],
          tags: [Tag.create(:d, "post-1")]
        )

      :ok = Store.insert_event(target, [])

      deletion =
        build_event(
          kind: 5,
          seckey: @seckey_b,
          created_at: ~U[2024-06-16 12:00:00Z],
          tags: [Tag.create(:a, "30001:#{target.pubkey}:post-1"), Tag.create(:k, "30001")]
        )

      payload = Message.create_event(deletion) |> Message.serialize()
      deletion_id = deletion.id

      assert {:push, [{:text, ok_json}], _state_after} = Engine.run(payload, state)

      assert [
               "OK",
               ^deletion_id,
               false,
               "rejected: deletion can only target events by same pubkey"
             ] = JSON.decode!(ok_json)

      assert {:ok, target_visible} = Store.query_events([%Filter{ids: [target.id]}], [])
      assert Enum.any?(target_visible, &(&1.id == target.id))
    end

    test "rejects regular events already deleted in store but still stores them" do
      state = ConnectionState.new()

      target =
        build_event(
          kind: 1,
          seckey: @seckey,
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      target_id = target.id

      deletion =
        build_event(
          kind: 5,
          seckey: @seckey,
          created_at: ~U[2024-06-16 12:00:00Z],
          tags: [Tag.create(:e, target.id)]
        )

      :ok = Store.insert_event(deletion, [])

      payload = Message.create_event(target) |> Message.serialize()

      assert {
               :push,
               [{:text, ok_json}],
               %ConnectionState{messages: 1} = state_after_target
             } = Engine.run(payload, state)

      assert ["OK", ^target_id, false, "rejected: event is deleted"] = JSON.decode!(ok_json)

      target_count =
        from(record in EventRecord, where: record.event_id == ^target.id)
        |> Repo.aggregate(:count, :event_id)

      assert target_count == 1

      deletion_count =
        from(record in EventRecord, where: record.event_id == ^deletion.id)
        |> Repo.aggregate(:count, :event_id)

      assert deletion_count == 1

      assert {
               :push,
               [{:text, dup_ok_json}],
               _state_after_duplicate
             } = Engine.run(payload, state_after_target)

      assert ["OK", ^target_id, false, "rejected: event is deleted"] = JSON.decode!(dup_ok_json)

      retried_target_count =
        from(record in EventRecord, where: record.event_id == ^target.id)
        |> Repo.aggregate(:count, :event_id)

      assert retried_target_count == 1

      assert {:ok, []} = Store.query_events([%Filter{ids: [target.id]}], [])
    end

    test "rejects regular events already deleted when deletion kind filter matches" do
      state = ConnectionState.new()

      target =
        build_event(
          kind: 1,
          seckey: @seckey,
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      target_id = target.id

      deletion =
        build_event(
          kind: 5,
          seckey: @seckey,
          created_at: ~U[2024-06-16 12:00:00Z],
          tags: [Tag.create(:e, target.id), Tag.create(:k, "1")]
        )

      :ok = Store.insert_event(deletion, [])

      payload = Message.create_event(target) |> Message.serialize()

      assert {
               :push,
               [{:text, ok_json}],
               %ConnectionState{messages: 1}
             } = Engine.run(payload, state)

      assert ["OK", ^target_id, false, "rejected: event is deleted"] = JSON.decode!(ok_json)
    end

    test "accepts regular events when deletion kind filter does not match" do
      state = ConnectionState.new()

      target =
        build_event(
          kind: 1,
          seckey: @seckey,
          created_at: ~U[2024-06-15 12:00:00Z]
        )

      target_id = target.id

      deletion =
        build_event(
          kind: 5,
          seckey: @seckey,
          created_at: ~U[2024-06-16 12:00:00Z],
          tags: [Tag.create(:e, target.id), Tag.create(:k, "7")]
        )

      :ok = Store.insert_event(deletion, [])

      payload = Message.create_event(target) |> Message.serialize()

      assert {
               :push,
               [{:text, ok_json}],
               %ConnectionState{messages: 1}
             } = Engine.run(payload, state)

      assert ["OK", ^target_id, true, ""] = JSON.decode!(ok_json)
    end

    test "rejects regular parameterized replaceable events already deleted via naddr" do
      state = ConnectionState.new()

      target =
        build_event(
          kind: 30_001,
          seckey: @seckey,
          created_at: ~U[2024-06-15 12:00:00Z],
          tags: [Tag.create(:d, "post-1")]
        )

      target_id = target.id

      deletion =
        build_event(
          kind: 5,
          seckey: @seckey,
          created_at: ~U[2024-06-16 12:00:00Z],
          tags: [
            Tag.create(:a, "30001:#{target.pubkey}:post-1"),
            Tag.create(:k, "30001")
          ]
        )

      :ok = Store.insert_event(deletion, [])

      payload = Message.create_event(target) |> Message.serialize()

      assert {
               :push,
               [{:text, ok_json}],
               %ConnectionState{messages: 1}
             } = Engine.run(payload, state)

      assert ["OK", ^target_id, false, "rejected: event is deleted"] = JSON.decode!(ok_json)
    end

    test "rejects protected events when no matching pubkey is authenticated" do
      state = ConnectionState.new()
      event = valid_event(tags: [Tag.create("-")])

      payload =
        event
        |> Message.create_event()
        |> Message.serialize()

      assert {:push, [{:text, ok_json}], %ConnectionState{messages: 1}} =
               Engine.run(payload, state)

      assert [
               "OK",
               event_id,
               false,
               "auth-required: protected event requires matching authenticated pubkey"
             ] = JSON.decode!(ok_json)

      assert event_id == event.id
      assert {:ok, []} = Store.query_events([%Filter{ids: [event.id]}], [])
    end

    test "rejects protected events when a different pubkey is authenticated" do
      event = valid_event(tags: [Tag.create("-")])

      state =
        ConnectionState.new()
        |> ConnectionState.authenticate_pubkey(Nostr.Crypto.pubkey(@seckey_b))

      payload =
        event
        |> Message.create_event()
        |> Message.serialize()

      assert {:push, [{:text, ok_json}], %ConnectionState{messages: 1}} =
               Engine.run(payload, state)

      assert [
               "OK",
               event_id,
               false,
               "auth-required: protected event requires matching authenticated pubkey"
             ] = JSON.decode!(ok_json)

      assert event_id == event.id
      assert {:ok, []} = Store.query_events([%Filter{ids: [event.id]}], [])
    end

    test "accepts protected events when author pubkey is authenticated" do
      event = valid_event(tags: [Tag.create("-")])

      state =
        ConnectionState.new()
        |> ConnectionState.authenticate_pubkey(event.pubkey)

      payload =
        event
        |> Message.create_event()
        |> Message.serialize()

      assert {:push, [{:text, ok_json}], %ConnectionState{messages: 1}} =
               Engine.run(payload, state)

      assert ["OK", event_id, true, ""] = JSON.decode!(ok_json)
      assert event_id == event.id

      assert {:ok, [stored_event]} = Store.query_events([%Filter{ids: [event.id]}], [])
      assert stored_event.id == event.id
    end
  end

  describe "AUTH end-to-end pipeline" do
    setup do
      original_auth = Application.get_env(:nostr_relay, :auth)
      original_relay_info = Application.get_env(:nostr_relay, :relay_info)

      on_exit(fn ->
        Application.put_env(:nostr_relay, :auth, original_auth)
        Application.put_env(:nostr_relay, :relay_info, original_relay_info)
      end)

      :ok
    end

    test "valid AUTH event passes through full pipeline and authenticates" do
      challenge = "test-challenge-end-to-end"
      set_relay_url("wss://relay.example.com")
      set_auth_mode(:none)

      state =
        ConnectionState.new()
        |> ConnectionState.with_challenge(challenge)

      event = auth_event(challenge: challenge, relay: "wss://relay.example.com")
      payload = JSON.encode!(["AUTH", event])

      assert {:push, [{:text, ok_json}], %ConnectionState{} = result_state} =
               Engine.run(payload, state)

      assert ["OK", _event_id, true, ""] = JSON.decode!(ok_json)
      assert ConnectionState.authenticated?(result_state)
    end

    test "AUTH event with wrong challenge is rejected through full pipeline" do
      challenge = "correct-challenge"
      set_relay_url("wss://relay.example.com")
      set_auth_mode(:none)

      state =
        ConnectionState.new()
        |> ConnectionState.with_challenge(challenge)

      event = auth_event(challenge: "wrong-challenge", relay: "wss://relay.example.com")
      payload = JSON.encode!(["AUTH", event])

      assert {:push, [{:text, ok_json}], %ConnectionState{} = result_state} =
               Engine.run(payload, state)

      assert ["OK", _event_id, false, "auth-required: challenge mismatch"] =
               JSON.decode!(ok_json)

      refute ConnectionState.authenticated?(result_state)
    end

    test "AUTH event with wrong kind is rejected through full pipeline" do
      challenge = "kind-check-challenge"
      set_relay_url("wss://relay.example.com")
      set_auth_mode(:none)

      state =
        ConnectionState.new()
        |> ConnectionState.with_challenge(challenge)

      # Build a kind-1 event with auth tags — wrong kind
      wrong_kind_event =
        1
        |> Event.create(
          tags: [
            Nostr.Tag.create(:relay, "wss://relay.example.com"),
            Nostr.Tag.create(:challenge, challenge)
          ],
          created_at: DateTime.utc_now()
        )
        |> Event.sign(@seckey)

      payload = JSON.encode!(["AUTH", wrong_kind_event])

      assert {:push, [{:text, ok_json}], %ConnectionState{} = result_state} =
               Engine.run(payload, state)

      assert ["OK", _event_id, false, "auth-required: invalid auth event kind"] =
               JSON.decode!(ok_json)

      refute ConnectionState.authenticated?(result_state)
    end

    test "AUTH enforcer rejects EVENT when auth required and not authenticated" do
      state = ConnectionState.new(auth_required: true)
      event = valid_event()

      payload =
        event
        |> Message.create_event()
        |> Message.serialize()

      assert {:push, [{:text, ok_json}], %ConnectionState{}} = Engine.run(payload, state)

      assert ["OK", _event_id, false, "auth-required:" <> _] = JSON.decode!(ok_json)
    end

    test "AUTH enforcer rejects REQ when auth required and not authenticated" do
      state = ConnectionState.new(auth_required: true)

      payload =
        %Nostr.Filter{}
        |> Message.request("sub-1")
        |> Message.serialize()

      assert {:push, [{:text, closed_json}], %ConnectionState{}} = Engine.run(payload, state)

      assert ["CLOSED", "sub-1", "auth-required:" <> _] = JSON.decode!(closed_json)
    end

    test "full AUTH then EVENT flow succeeds through pipeline" do
      challenge = "full-flow-challenge"
      set_relay_url("wss://relay.example.com")
      set_auth_mode(:none)

      state =
        ConnectionState.new(auth_required: true)
        |> ConnectionState.with_challenge(challenge)

      # Step 1: authenticate
      auth = auth_event(challenge: challenge, relay: "wss://relay.example.com")
      auth_payload = JSON.encode!(["AUTH", auth])

      assert {:push, [{:text, ok_json}], authed_state} = Engine.run(auth_payload, state)
      assert ["OK", _, true, ""] = JSON.decode!(ok_json)
      assert ConnectionState.authenticated?(authed_state)

      # Step 2: send EVENT — should succeed now
      event = valid_event()
      event_payload = Message.create_event(event) |> Message.serialize()

      assert {:push, [{:text, event_ok}], _final_state} =
               Engine.run(event_payload, authed_state)

      assert ["OK", _, true, ""] = JSON.decode!(event_ok)
    end
  end

  defmodule InvalidResultStage do
    @moduledoc false

    @behaviour Stage

    @impl Stage
    def call(%Context{} = _context, _options), do: {:ok, :not_a_context}
  end

  defp valid_event do
    valid_event([])
  end

  defp valid_event(opts) when is_list(opts) do
    created_at = Keyword.get(opts, :created_at, ~U[2024-01-01 00:00:00Z])
    kind = Keyword.get(opts, :kind, 1)
    seckey = Keyword.get(opts, :seckey, @seckey)
    tags = Keyword.get(opts, :tags, [])
    content = Keyword.get(opts, :content, "relay ack")

    kind
    |> Event.create(content: content, created_at: created_at, tags: tags)
    |> Event.sign(seckey)
  end

  defp build_event(opts) when is_list(opts), do: valid_event(opts)

  defp auth_event(opts) do
    challenge = Keyword.fetch!(opts, :challenge)
    relay = Keyword.fetch!(opts, :relay)

    tags = [
      Nostr.Tag.create(:relay, relay),
      Nostr.Tag.create(:challenge, challenge)
    ]

    22_242
    |> Event.create(tags: tags, created_at: DateTime.utc_now())
    |> Event.sign(@seckey)
  end

  defp set_relay_url(url) do
    info = Application.get_env(:nostr_relay, :relay_info, [])
    Application.put_env(:nostr_relay, :relay_info, Keyword.put(info, :url, url))
  end

  defp set_auth_mode(mode) do
    auth = Application.get_env(:nostr_relay, :auth, [])
    Application.put_env(:nostr_relay, :auth, Keyword.put(auth, :mode, mode))
  end

  defp set_max_message_length(max_message_length) when is_integer(max_message_length) do
    relay_info = Application.get_env(:nostr_relay, :relay_info, [])
    limitation = Keyword.get(relay_info, :limitation, %{})
    new_limitation = Map.put(limitation, :max_message_length, max_message_length)

    Application.put_env(
      :nostr_relay,
      :relay_info,
      Keyword.put(relay_info, :limitation, new_limitation)
    )
  end

  defp set_max_content_length(max_content_length) when is_integer(max_content_length) do
    relay_info = Application.get_env(:nostr_relay, :relay_info, [])
    limitation = Keyword.get(relay_info, :limitation, %{})
    new_limitation = Map.put(limitation, :max_content_length, max_content_length)

    Application.put_env(
      :nostr_relay,
      :relay_info,
      Keyword.put(relay_info, :limitation, new_limitation)
    )
  end
end
