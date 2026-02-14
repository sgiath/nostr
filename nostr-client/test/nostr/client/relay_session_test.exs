defmodule Nostr.Client.RelaySessionTest do
  use ExUnit.Case, async: false

  alias Nostr.Client
  alias Nostr.Client.RelaySession
  alias Nostr.Client.SessionKey
  alias Nostr.Client.TestSupport

  describe "publish/3" do
    test "publishes and resolves on OK" do
      relay_url = TestSupport.relay_url()

      {:ok, pid} =
        Client.get_or_start_session(
          relay_url,
          pubkey: TestSupport.TestSigner.pubkey(),
          signer: TestSupport.TestSigner,
          transport: TestSupport.FakeTransport,
          transport_opts: [test_pid: self()],
          notify: self()
        )

      send(pid, :upgrade_ok)
      assert_receive {:nostr_client, :connected, ^pid, ^relay_url}

      event = TestSupport.signed_event("publish me")

      task = Task.async(fn -> RelaySession.publish(pid, event) end)

      assert_receive {:fake_transport, :sent, _relay_pid, outbound_payload}
      assert {:event, %Nostr.Event{id: event_id}} = Nostr.Message.parse(outbound_payload)
      assert event_id == event.id

      ok_payload = Nostr.Message.ok(event.id, true, "") |> Nostr.Message.serialize()
      send(pid, {:ws_data, ok_payload})

      assert :ok == Task.await(task)

      assert :ok == RelaySession.close(pid)
      assert_receive {:nostr_client, :disconnected, ^pid, :normal}
    end

    test "sends auth event when relay sends challenge" do
      relay_url = TestSupport.relay_url()

      {:ok, pid} =
        Client.get_or_start_session(
          relay_url,
          pubkey: TestSupport.TestSigner.pubkey(),
          signer: TestSupport.TestSigner,
          transport: TestSupport.FakeTransport,
          transport_opts: [test_pid: self()],
          notify: self()
        )

      send(pid, :upgrade_ok)
      assert_receive {:nostr_client, :connected, ^pid, ^relay_url}

      challenge_payload = Nostr.Message.auth("challenge-1") |> Nostr.Message.serialize()
      send(pid, {:ws_data, challenge_payload})

      assert_receive {:fake_transport, :sent, _relay_pid, outbound_payload}
      assert {:auth, %Nostr.Event{kind: 22_242}} = Nostr.Message.parse(outbound_payload)

      assert :ok == RelaySession.close(pid)
      assert_receive {:nostr_client, :disconnected, ^pid, :normal}
    end

    test "does not restart after graceful close" do
      relay_url = TestSupport.relay_url()

      opts = [
        pubkey: TestSupport.TestSigner.pubkey(),
        signer: TestSupport.TestSigner,
        transport: TestSupport.FakeTransport,
        transport_opts: [test_pid: self()],
        notify: self()
      ]

      {:ok, pid} = Client.get_or_start_session(relay_url, opts)
      assert_receive {:nostr_client, :connecting, ^pid, ^relay_url}

      send(pid, :upgrade_ok)
      assert_receive {:nostr_client, :connected, ^pid, ^relay_url}

      assert :ok == RelaySession.close(pid)
      assert_receive {:nostr_client, :disconnected, ^pid, :normal}

      refute_receive {:nostr_client, :connecting, _other_pid, ^relay_url}, 200

      {:ok, key} = SessionKey.build(relay_url, TestSupport.TestSigner.pubkey())
      assert Registry.lookup(Nostr.Client.SessionRegistry, key) == []

      {:ok, new_pid} = Client.get_or_start_session(relay_url, opts)
      assert new_pid != pid
      assert_receive {:nostr_client, :connecting, ^new_pid, ^relay_url}

      assert :ok == RelaySession.close(new_pid)
      assert_receive {:nostr_client, :disconnected, ^new_pid, :normal}
    end
  end

  describe "count/3" do
    test "sends COUNT and resolves on COUNT response" do
      relay_url = TestSupport.relay_url()

      {:ok, pid} =
        Client.get_or_start_session(
          relay_url,
          pubkey: TestSupport.TestSigner.pubkey(),
          signer: TestSupport.TestSigner,
          transport: TestSupport.FakeTransport,
          transport_opts: [test_pid: self()],
          notify: self()
        )

      send(pid, :upgrade_ok)
      assert_receive {:nostr_client, :connected, ^pid, ^relay_url}

      task = Task.async(fn -> RelaySession.count(pid, [%Nostr.Filter{kinds: [1]}]) end)

      assert_receive {:fake_transport, :sent, _relay_pid, outbound_payload}

      assert {:count, query_id, [%Nostr.Filter{kinds: [1]}]} =
               Nostr.Message.parse(outbound_payload)

      hll = String.duplicate("0", 512)

      count_payload =
        {:count, query_id, %{count: 7, approximate: true, hll: hll}}
        |> Nostr.Message.serialize()

      send(pid, {:ws_data, count_payload})

      assert {:ok, %{count: 7, approximate: true, hll: hll}} == Task.await(task)

      assert :ok == RelaySession.close(pid)
      assert_receive {:nostr_client, :disconnected, ^pid, :normal}
    end

    test "returns closed error when relay refuses count" do
      relay_url = TestSupport.relay_url()

      {:ok, pid} =
        Client.get_or_start_session(
          relay_url,
          pubkey: TestSupport.TestSigner.pubkey(),
          signer: TestSupport.TestSigner,
          transport: TestSupport.FakeTransport,
          transport_opts: [test_pid: self()],
          notify: self()
        )

      send(pid, :upgrade_ok)
      assert_receive {:nostr_client, :connected, ^pid, ^relay_url}

      task = Task.async(fn -> RelaySession.count(pid, [%Nostr.Filter{kinds: [1]}]) end)

      assert_receive {:fake_transport, :sent, _relay_pid, outbound_payload}
      assert {:count, query_id, _filters} = Nostr.Message.parse(outbound_payload)

      closed_payload =
        Nostr.Message.closed(query_id, "rate-limited: count disabled")
        |> Nostr.Message.serialize()

      send(pid, {:ws_data, closed_payload})

      assert {:error, {:closed, "rate-limited: count disabled"}} == Task.await(task)

      assert :ok == RelaySession.close(pid)
      assert_receive {:nostr_client, :disconnected, ^pid, :normal}
    end

    test "fails pending count when session closes" do
      relay_url = TestSupport.relay_url()

      {:ok, pid} =
        Client.get_or_start_session(
          relay_url,
          pubkey: TestSupport.TestSigner.pubkey(),
          signer: TestSupport.TestSigner,
          transport: TestSupport.FakeTransport,
          transport_opts: [test_pid: self()],
          notify: self()
        )

      send(pid, :upgrade_ok)
      assert_receive {:nostr_client, :connected, ^pid, ^relay_url}

      task = Task.async(fn -> RelaySession.count(pid, [%Nostr.Filter{kinds: [1]}]) end)
      assert_receive {:fake_transport, :sent, _relay_pid, _outbound_payload}

      assert :ok == RelaySession.close(pid)
      assert_receive {:nostr_client, :disconnected, ^pid, :normal}

      assert {:error, {:session_stopped, :normal}} == Task.await(task)
    end
  end
end
