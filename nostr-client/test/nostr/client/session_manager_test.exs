defmodule Nostr.Client.SessionManagerTest do
  use ExUnit.Case, async: false

  alias Nostr.Client
  alias Nostr.Client.RelaySession
  alias Nostr.Client.TestSupport

  describe "get_or_start_session/2" do
    test "returns the same pid for same relay and pubkey" do
      relay_url = TestSupport.relay_url()

      opts = [
        pubkey: TestSupport.TestSigner.pubkey(),
        signer: TestSupport.TestSigner,
        transport: TestSupport.FakeTransport,
        transport_opts: [test_pid: self()],
        notify: self()
      ]

      {:ok, pid_a} = Client.get_or_start_session(relay_url, opts)
      {:ok, pid_b} = Client.get_or_start_session(relay_url, opts)

      assert pid_a == pid_b

      send(pid_a, :upgrade_ok)
      assert_receive {:nostr_client, :connected, ^pid_a, ^relay_url}

      assert :ok == RelaySession.close(pid_a)
      assert_receive {:nostr_client, :disconnected, ^pid_a, :normal}
    end

    test "requires signer option" do
      relay_url = TestSupport.relay_url()

      assert {:error, {:missing_option, :signer}} =
               Client.get_or_start_session(relay_url, pubkey: TestSupport.TestSigner.pubkey())
    end
  end
end
