defmodule Nostr.Client.RelaySessionExternalTest do
  @moduledoc """
  End-to-end tests against a real external relay.

  These tests read the target relay URL from:

      config :nostr_client, e2e_relay_url: "wss://nostr.sgiath.dev/"

  and are tagged `:external`, so they are excluded by default.
  """

  use ExUnit.Case, async: false

  alias Nostr.Client
  alias Nostr.Client.RelaySession
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

  describe "external relay session" do
    test "connects to configured relay" do
      relay_url = Application.fetch_env!(:nostr_client, :e2e_relay_url)

      {:ok, pid} =
        Client.get_or_start_session(
          relay_url,
          pubkey: ExternalSigner.pubkey(),
          signer: ExternalSigner,
          notify: self()
        )

      on_exit(fn ->
        if Process.alive?(pid) do
          :ok = RelaySession.close(pid)
        end
      end)

      assert :ok = TestSupport.wait_for_connected(pid, relay_url)
      assert :connected == RelaySession.status(pid)

      ref = Process.monitor(pid)

      assert :ok == RelaySession.close(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end
end
