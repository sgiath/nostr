defmodule Nostr.Client.SessionExternalTest do
  @moduledoc """
  End-to-end smoke tests for multi-relay logical sessions.

  These tests are tagged `:external` and excluded by default.
  """

  use ExUnit.Case, async: false

  alias Nostr.Client
  alias Nostr.Client.TestSupport

  @moduletag :external

  defmodule ExternalSigner do
    @behaviour Nostr.Client.AuthSigner

    @seckey String.duplicate("2", 64)
    @pubkey Nostr.Crypto.pubkey(@seckey)

    @spec pubkey() :: binary()
    def pubkey, do: @pubkey

    @impl true
    def sign_client_auth(pubkey, relay_url, challenge) when pubkey == @pubkey do
      auth = Nostr.Event.ClientAuth.create(relay_url, challenge, pubkey: pubkey)
      {:ok, Nostr.Event.sign(auth.event, @seckey)}
    end

    def sign_client_auth(_pubkey, _relay_url, _challenge) do
      {:error, :unknown_pubkey}
    end
  end

  setup do
    relay_url = Application.fetch_env!(:nostr_client, :e2e_relay_url)

    case TestSupport.relay_available?(relay_url) do
      :ok -> :ok
      {:error, reason} -> {:skip, "e2e relay unavailable: #{inspect(reason)}"}
    end
  end

  describe "multi-relay session" do
    test "starts session and attaches configured relay" do
      relay_url = Application.fetch_env!(:nostr_client, :e2e_relay_url)

      {:ok, session_pid} =
        Client.start_session(
          pubkey: ExternalSigner.pubkey(),
          signer: ExternalSigner,
          notify: self(),
          relays: [{relay_url, :read_write}]
        )

      on_exit(fn ->
        if Process.alive?(session_pid) do
          :ok = Client.stop_session(session_pid)
        end
      end)

      assert {:ok, [relay_entry]} = Client.list_relays(session_pid)
      assert relay_entry.relay_url == relay_url

      assert :ok = TestSupport.wait_for_connected(session_pid, relay_url)

      assert :ok = Client.stop_session(session_pid)
    end
  end
end
