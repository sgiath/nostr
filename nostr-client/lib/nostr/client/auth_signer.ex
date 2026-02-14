defmodule Nostr.Client.AuthSigner do
  @moduledoc """
  Behaviour for signing NIP-42 ClientAuth events.

  `RelaySession` stores only `pubkey` and a signer module reference.
  Secret key material must stay outside the session process.
  """

  @callback sign_client_auth(pubkey :: binary(), relay_url :: binary(), challenge :: binary()) ::
              {:ok, Nostr.Event.t()} | {:error, term()}
end
