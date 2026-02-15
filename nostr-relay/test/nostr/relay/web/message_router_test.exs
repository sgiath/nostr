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
        |> Message.ok(true, "event accepted")
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

    test "dispatches EVENT to subscriptions matching active filters", %{state: state} do
      filter = %Filter{kinds: [1]}

      request =
        filter
        |> Message.request("live-sub")
        |> Message.serialize()

      {:push, [{:text, _eose}], active_state} = MessageRouter.route_frame(request, state)

      matching_event = valid_event(created_by: @author_one)
      event_payload = Message.create_event(matching_event) |> Message.serialize()

      ok_payload = Message.ok(matching_event.id, true, "event accepted") |> Message.serialize()
      event_frame = Message.event(matching_event, "live-sub") |> Message.serialize()

      assert {
               :push,
               [{:text, ^ok_payload}, {:text, ^event_frame}],
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
        Message.ok(non_matching_event.id, true, "event accepted") |> Message.serialize()

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
end
