defmodule Nostr.Client.SessionSubscriptionTest do
  use ExUnit.Case, async: false

  alias Nostr.Client
  alias Nostr.Client.SessionSubscription
  alias Nostr.Client.TestSupport

  describe "start_session_subscription/3" do
    test "forwards events from all relays with relay attribution" do
      relay_a = TestSupport.relay_url()
      relay_b = TestSupport.relay_url()
      filter = %Nostr.Filter{kinds: [1]}

      {:ok, session_pid} =
        Client.start_session(
          pubkey: TestSupport.TestSigner.pubkey(),
          signer: TestSupport.TestSigner,
          transport: TestSupport.FakeTransport,
          transport_opts: [test_pid: self()],
          notify: self(),
          relays: [{relay_a, :read_write}, {relay_b, :read_write}]
        )

      assert {:ok, relays} = Client.list_relays(session_pid)

      Enum.each(relays, fn relay ->
        send(relay.session_pid, :upgrade_ok)
      end)

      assert_receive {:nostr_client, :connected, _pid, _relay_url}
      assert_receive {:nostr_client, :connected, _pid, _relay_url}

      {:ok, subscription_pid} =
        Client.start_session_subscription(session_pid, [filter], consumer: self())

      assert_receive {:fake_transport, :sent, _relay_pid, req_payload_a}
      assert {:req, sub_id_a, [_parsed_filter_a]} = Nostr.Message.parse(req_payload_a)

      assert_receive {:fake_transport, :sent, _relay_pid, req_payload_b}
      assert {:req, sub_id_b, [_parsed_filter_b]} = Nostr.Message.parse(req_payload_b)

      sub_state = SessionSubscription.state(subscription_pid)

      relay_by_sub_id =
        Enum.into(sub_state.relays, %{}, fn {_relay_url, relay_state} ->
          {relay_state.relay_sub_id, {relay_state.relay_url, relay_state.session_pid}}
        end)

      event = TestSupport.signed_event("duplicate across relays")

      {relay_url_a, relay_pid_a} = Map.fetch!(relay_by_sub_id, sub_id_a)
      payload_a = Nostr.Message.event(event, sub_id_a) |> Nostr.Message.serialize()
      send(relay_pid_a, {:ws_data, payload_a})

      assert_receive {:nostr_session_subscription, ^subscription_pid,
                      {:event, ^relay_url_a, parsed_event_a}}

      assert parsed_event_a.id == event.id

      {relay_url_b, relay_pid_b} = Map.fetch!(relay_by_sub_id, sub_id_b)
      payload_b = Nostr.Message.event(event, sub_id_b) |> Nostr.Message.serialize()
      send(relay_pid_b, {:ws_data, payload_b})

      assert_receive {:nostr_session_subscription, ^subscription_pid,
                      {:event, ^relay_url_b, parsed_event_b}}

      assert parsed_event_b.id == event.id

      assert relay_url_a != relay_url_b

      assert :ok = Client.stop_subscription(subscription_pid)
      assert :ok = Client.stop_session(session_pid)
    end

    test "registers on relays added at runtime" do
      relay_a = TestSupport.relay_url()
      relay_b = TestSupport.relay_url()
      filter = %Nostr.Filter{kinds: [1]}

      {:ok, session_pid} =
        Client.start_session(
          pubkey: TestSupport.TestSigner.pubkey(),
          signer: TestSupport.TestSigner,
          transport: TestSupport.FakeTransport,
          transport_opts: [test_pid: self()],
          notify: self(),
          relays: [{relay_a, :read_write}]
        )

      assert {:ok, [relay_entry_a]} = Client.list_relays(session_pid)
      send(relay_entry_a.session_pid, :upgrade_ok)
      assert_receive {:nostr_client, :connected, _pid, _relay_url}

      {:ok, subscription_pid} =
        Client.start_session_subscription(session_pid, [filter], consumer: self())

      assert_receive {:fake_transport, :sent, _relay_pid, _first_req_payload}

      assert :ok = Client.add_relay(session_pid, relay_b, :read_write)

      assert {:ok, relays_after_add} = Client.list_relays(session_pid)
      relay_entry_b = Enum.find(relays_after_add, &(&1.relay_url == relay_b))
      send(relay_entry_b.session_pid, :upgrade_ok)
      assert_receive {:nostr_client, :connected, _pid, ^relay_b}

      assert_receive {:fake_transport, :sent, _relay_pid, second_req_payload}, 1_000
      assert {:req, second_sub_id, [_parsed_filter]} = Nostr.Message.parse(second_req_payload)

      event = TestSupport.signed_event("from added relay")
      event_payload = Nostr.Message.event(event, second_sub_id) |> Nostr.Message.serialize()
      send(relay_entry_b.session_pid, {:ws_data, event_payload})

      assert_receive {:nostr_session_subscription, ^subscription_pid,
                      {:event, ^relay_b, parsed_event}}

      assert parsed_event.id == event.id

      assert :ok = Client.stop_subscription(subscription_pid)
      assert :ok = Client.stop_session(session_pid)
    end
  end
end
