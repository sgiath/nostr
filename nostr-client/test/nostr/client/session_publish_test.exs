defmodule Nostr.Client.SessionPublishTest do
  use ExUnit.Case, async: false

  alias Nostr.Client
  alias Nostr.Client.TestSupport

  describe "publish_session/3" do
    test "fans out to writable relays and returns per-relay results" do
      relay_a = TestSupport.relay_url()
      relay_b = TestSupport.relay_url()

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

      event = TestSupport.signed_event("publish all")
      task = Task.async(fn -> Client.publish_session(session_pid, event) end)

      assert_receive {:fake_transport, :sent, _relay_pid, payload_a}
      assert {:event, %Nostr.Event{id: id_a}} = Nostr.Message.parse(payload_a)
      assert id_a == event.id

      assert_receive {:fake_transport, :sent, _relay_pid, payload_b}
      assert {:event, %Nostr.Event{id: id_b}} = Nostr.Message.parse(payload_b)
      assert id_b == event.id

      ok_payload = Nostr.Message.ok(event.id, true, "") |> Nostr.Message.serialize()

      Enum.each(relays, fn relay ->
        send(relay.session_pid, {:ws_data, ok_payload})
      end)

      assert {:ok, result_map} = Task.await(task)
      assert Map.keys(result_map) |> Enum.sort() == Enum.sort([relay_a, relay_b])
      assert result_map[relay_a] == :ok
      assert result_map[relay_b] == :ok

      assert :ok = Client.stop_session(session_pid)
    end

    test "returns error when there are no writable relays" do
      relay_url = TestSupport.relay_url()

      {:ok, session_pid} =
        Client.start_session(
          pubkey: TestSupport.TestSigner.pubkey(),
          signer: TestSupport.TestSigner,
          transport: TestSupport.FakeTransport,
          transport_opts: [test_pid: self()],
          relays: [{relay_url, :read}]
        )

      assert {:error, :no_writable_relays} =
               Client.publish_session(session_pid, TestSupport.signed_event("readonly"))

      assert :ok = Client.stop_session(session_pid)
    end
  end
end
