# Relay Auth and Info

## Relay Information

NIP-11 relay information documents are fetched from the relay
`/.well-known/nostr.json` endpoint.

```elixir
{:ok, info} = Nostr.Client.get_relay_info("wss://relay.example")

info.supported_nips
info.limitation
info.extra
```

Use `Nostr.Client.RelayInfo.fetch_raw/2` if the raw relay document is needed.

## Client Authentication

Relays may send an `AUTH` challenge or reject a write until the client
authenticates. Pass a signer module that implements `Nostr.Client.AuthSigner`:

```elixir
defmodule MySigner do
  @behaviour Nostr.Client.AuthSigner

  @impl true
  def sign_client_auth(pubkey, relay_url, challenge) do
    auth = Nostr.Event.ClientAuth.create(relay_url, challenge, pubkey: pubkey)
    {:ok, Nostr.Event.sign(auth.event, secret_key())}
  end

  defp secret_key do
    System.fetch_env!("NOSTR_SECRET_KEY")
  end
end
```

Then pass it with the public key:

```elixir
opts = [
  pubkey: pubkey,
  signer: MySigner
]
```

Relay sessions store only the public key and the signer module. Keep private key
material outside `nostr_client`.
