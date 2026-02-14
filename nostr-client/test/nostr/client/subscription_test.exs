defmodule Nostr.Client.SubscriptionTest do
  use ExUnit.Case, async: false

  alias Nostr.Client
  alias Nostr.Client.RelaySession
  alias Nostr.Client.TestSupport

  describe "subscription lifecycle" do
    test "forwards EVENT, EOSE and CLOSED to consumer" do
      relay_url = TestSupport.relay_url()
      sub_id = "sub-1"
      filter = %Nostr.Filter{kinds: [1]}

      {:ok, session_pid} =
        Client.get_or_start_session(
          relay_url,
          pubkey: TestSupport.TestSigner.pubkey(),
          signer: TestSupport.TestSigner,
          transport: TestSupport.FakeTransport,
          transport_opts: [test_pid: self()],
          notify: self()
        )

      send(session_pid, :upgrade_ok)
      assert_receive {:nostr_client, :connected, ^session_pid, ^relay_url}

      {:ok, subscription_pid} =
        Client.start_subscription(
          relay_url,
          [filter],
          pubkey: TestSupport.TestSigner.pubkey(),
          signer: TestSupport.TestSigner,
          transport: TestSupport.FakeTransport,
          transport_opts: [test_pid: self()],
          sub_id: sub_id,
          consumer: self()
        )

      assert_receive {:fake_transport, :sent, _relay_pid, req_payload}
      assert {:req, ^sub_id, [_parsed_filter]} = Nostr.Message.parse(req_payload)

      event = TestSupport.signed_event("incoming")

      event_payload = Nostr.Message.event(event, sub_id) |> Nostr.Message.serialize()
      eose_payload = Nostr.Message.eose(sub_id) |> Nostr.Message.serialize()

      closed_payload =
        Nostr.Message.closed(sub_id, "closed by relay") |> Nostr.Message.serialize()

      send(session_pid, {:ws_data, event_payload})
      assert_receive {:nostr_subscription, ^subscription_pid, {:event, parsed_event}}
      assert parsed_event.id == event.id

      send(session_pid, {:ws_data, eose_payload})
      assert_receive {:nostr_subscription, ^subscription_pid, :eose}

      monitor_ref = Process.monitor(subscription_pid)
      send(session_pid, {:ws_data, closed_payload})
      assert_receive {:nostr_subscription, ^subscription_pid, {:closed, "closed by relay"}}
      assert_receive {:DOWN, ^monitor_ref, :process, ^subscription_pid, :normal}

      assert :ok == RelaySession.close(session_pid)
      assert_receive {:nostr_client, :disconnected, ^session_pid, :normal}
    end
  end
end
