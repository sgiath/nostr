defmodule Nostr.Client.PublishValidationExternalTest do
  @moduledoc """
  End-to-end tests verifying NIP-01 relay rejection of events with
  invalid signatures or tampered hash IDs.

  Tagged `:external`, excluded by default.
  """

  use ExUnit.Case, async: false

  alias Nostr.Client
  alias Nostr.Client.RelaySession
  alias Nostr.Client.TestSupport

  @moduletag :external

  @seckey String.duplicate("2", 64)
  @pubkey Nostr.Crypto.pubkey(@seckey)

  defmodule ExternalSigner do
    @moduledoc false

    @behaviour Nostr.Client.AuthSigner

    @seckey String.duplicate("2", 64)
    @pubkey Nostr.Crypto.pubkey(@seckey)

    @spec pubkey() :: binary()
    def pubkey, do: @pubkey

    @impl true
    def sign_client_auth(pubkey, relay_url, challenge)
        when pubkey == @pubkey do
      auth =
        Nostr.Event.ClientAuth.create(
          relay_url,
          challenge,
          pubkey: pubkey
        )

      {:ok, Nostr.Event.sign(auth.event, @seckey)}
    end

    def sign_client_auth(_pubkey, _relay_url, _challenge) do
      {:error, :unknown_pubkey}
    end
  end

  setup do
    relay_url = Application.fetch_env!(:nostr_client, :e2e_relay_url)

    case TestSupport.relay_available?(relay_url) do
      :ok ->
        opts = [
          pubkey: ExternalSigner.pubkey(),
          signer: ExternalSigner,
          notify: self()
        ]

        {:ok, pid} = Client.get_or_start_session(relay_url, opts)

        on_exit(fn ->
          if Process.alive?(pid), do: RelaySession.close(pid)
        end)

        assert :ok = TestSupport.wait_for_connected(pid, relay_url)

        %{session_pid: pid}

      {:error, reason} ->
        {:skip, "e2e relay unavailable: #{inspect(reason)}"}
    end
  end

  describe "invalid signature" do
    test "relay rejects event with tampered Schnorr signature",
         %{session_pid: pid} do
      event = signed_event("bad sig")
      bad_sig = String.duplicate("a", 128)
      tampered = %{event | sig: bad_sig}

      assert {:error, {:publish_rejected, message}} =
               RelaySession.publish(pid, tampered, 15_000)

      assert_reject_reason(message)
    end
  end

  describe "invalid event ID" do
    test "relay rejects event with wrong hash ID but correct signature",
         %{session_pid: pid} do
      event = signed_event("bad id")
      bad_id = String.duplicate("b", 64)
      tampered = %{event | id: bad_id, sig: Nostr.Crypto.sign(bad_id, @seckey)}

      assert {:error, {:publish_rejected, message}} =
               RelaySession.publish(pid, tampered, 15_000)

      assert_reject_reason(message)
    end

    test "relay rejects event with content modified after signing",
         %{session_pid: pid} do
      event = signed_event("original content")
      tampered = %{event | content: "tampered after signing"}

      assert {:error, {:publish_rejected, message}} =
               RelaySession.publish(pid, tampered, 15_000)

      assert_reject_reason(message)
    end
  end

  defp assert_reject_reason(message) do
    assert is_binary(message)
    assert byte_size(message) > 0
  end

  defp signed_event(content) do
    suffix = System.unique_integer([:positive])

    1
    |> Nostr.Event.create(pubkey: @pubkey, content: "#{content} #{suffix}")
    |> Nostr.Event.sign(@seckey)
  end
end
