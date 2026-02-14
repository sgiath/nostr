defmodule Nostr.Client.SessionTest do
  use ExUnit.Case, async: false

  alias Nostr.Client
  alias Nostr.Client.TestSupport

  describe "relay membership" do
    test "adds, updates, lists, and removes relays" do
      {:ok, session_pid} =
        Client.start_session(
          pubkey: TestSupport.TestSigner.pubkey(),
          signer: TestSupport.TestSigner,
          transport: TestSupport.FakeTransport,
          transport_opts: [test_pid: self()]
        )

      relay_a = TestSupport.relay_url()
      relay_b = TestSupport.relay_url()

      assert :ok = Client.add_relay(session_pid, relay_a, :read)
      assert :ok = Client.add_relay(session_pid, relay_b, :read_write)

      assert {:ok, relays} = Client.list_relays(session_pid)
      assert Enum.map(relays, & &1.relay_url) == Enum.sort([relay_a, relay_b])

      assert :ok = Client.update_relay_mode(session_pid, relay_a, :read_write)

      assert {:ok, relays_after_update} = Client.list_relays(session_pid)

      updated_a = Enum.find(relays_after_update, &(&1.relay_url == relay_a))
      assert updated_a.mode == :read_write

      assert :ok = Client.remove_relay(session_pid, relay_a)

      assert {:ok, relays_after_remove} = Client.list_relays(session_pid)
      assert Enum.map(relays_after_remove, & &1.relay_url) == [relay_b]

      assert :ok = Client.stop_session(session_pid)
    end
  end
end
