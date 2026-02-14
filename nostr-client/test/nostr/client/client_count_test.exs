defmodule Nostr.Client.ClientCountTest do
  use ExUnit.Case, async: false

  alias Nostr.Client
  alias Nostr.Client.RelaySession
  alias Nostr.Client.TestSupport

  describe "count/4" do
    test "counts over a single relay session context" do
      relay_url = TestSupport.relay_url()

      opts = [
        pubkey: TestSupport.TestSigner.pubkey(),
        signer: TestSupport.TestSigner,
        transport: TestSupport.FakeTransport,
        transport_opts: [test_pid: self()],
        notify: self()
      ]

      {:ok, session_pid} = Client.get_or_start_session(relay_url, opts)
      send(session_pid, :upgrade_ok)
      assert_receive {:nostr_client, :connected, ^session_pid, ^relay_url}

      task = Task.async(fn -> Client.count(relay_url, [%Nostr.Filter{kinds: [1]}], opts) end)

      assert_receive {:fake_transport, :sent, _relay_pid, outbound_payload}
      assert {:count, query_id, _filters} = Nostr.Message.parse(outbound_payload)

      count_payload = {:count, query_id, %{count: 5}} |> Nostr.Message.serialize()
      send(session_pid, {:ws_data, count_payload})

      assert {:ok, %{count: 5}} == Task.await(task)

      assert :ok == RelaySession.close(session_pid)
      assert_receive {:nostr_client, :disconnected, ^session_pid, :normal}
    end

    test "returns error for invalid filters" do
      relay_url = TestSupport.relay_url()

      opts = [
        pubkey: TestSupport.TestSigner.pubkey(),
        signer: TestSupport.TestSigner,
        transport: TestSupport.FakeTransport,
        transport_opts: [test_pid: self()],
        notify: self()
      ]

      {:ok, session_pid} = Client.get_or_start_session(relay_url, opts)
      send(session_pid, :upgrade_ok)
      assert_receive {:nostr_client, :connected, ^session_pid, ^relay_url}

      assert {:error, :invalid_filters} = Client.count(relay_url, [], opts)

      assert :ok == RelaySession.close(session_pid)
      assert_receive {:nostr_client, :disconnected, ^session_pid, :normal}
    end
  end
end
