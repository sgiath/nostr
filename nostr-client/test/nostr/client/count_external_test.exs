defmodule Nostr.Client.CountExternalTest do
  @moduledoc """
  End-to-end COUNT tests against a real external relay.

  These tests are tagged `:external` and excluded by default.
  """

  use ExUnit.Case, async: false

  alias Nostr.Client
  alias Nostr.Client.RelaySession

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

  describe "count/4" do
    @tag skip: "nostr.sgiath.dev does not support COUNT"
    test "returns COUNT payload from configured relay" do
      relay_url = Application.fetch_env!(:nostr_client, :e2e_relay_url)

      opts = [
        pubkey: ExternalSigner.pubkey(),
        signer: ExternalSigner,
        notify: self()
      ]

      {:ok, session_pid} = Client.get_or_start_session(relay_url, opts)

      on_exit(fn ->
        if Process.alive?(session_pid) do
          :ok = RelaySession.close(session_pid)
        end
      end)

      assert_receive {:nostr_client, :connected, ^session_pid, ^relay_url}, 15_000

      assert {:ok, payload} =
               Client.count(relay_url, [%Nostr.Filter{kinds: [1]}], opts, 15_000)

      assert is_integer(payload.count)
      assert payload.count >= 0
    end
  end
end
