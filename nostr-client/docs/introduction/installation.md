# Installation

Add `nostr_client` to your dependencies:

```elixir
def deps do
  [
    {:nostr_client, "~> 0.1.0"}
  ]
end
```

`nostr_client` depends on `nostr_lib` for events, filters, NIP helpers, and
cryptographic protocol support.

## Supervision

`nostr_client` is an OTP application. In normal Mix applications, its supervision
tree starts automatically when the dependency is started.

If your runtime starts applications manually, ensure `:nostr_client` is started
before calling `Nostr.Client` APIs:

```elixir
Application.ensure_all_started(:nostr_client)
```

## Test Relay

This repository includes an end-to-end helper that starts the local relay and
runs the client tests tagged as external:

```bash
./e2e
```

Manual mode from the repository root:

```bash
cd nostr-relay
MIX_ENV=dev NOSTR_RELAY_ENABLED=true NOSTR_RELAY_PORT=4002 mix run --no-halt

cd ../nostr-client
NOSTR_E2E_RELAY_URL=ws://127.0.0.1:4002/ mix test --include external
```
