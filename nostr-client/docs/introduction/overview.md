# Overview

`nostr_client` is an OTP WebSocket client for the Nostr client-relay protocol.
It builds on `nostr_lib` for protocol types and event signing while this package
owns relay connections, subscriptions, authentication, and multi-relay sessions.

Use it when an Elixir application needs to:

- publish signed events to one relay or many relays
- subscribe to relay event streams with NIP-01 filters
- fetch NIP-11 relay information documents
- answer NIP-42 `AUTH` challenges through an application-owned signer
- send NIP-45 `COUNT` requests
- run NIP-77 negentropy message lifecycles

## Protocol Coverage

The client focuses on the relay-facing protocol surface:

- **NIP-01**: `EVENT`, `REQ`, `CLOSE`, `OK`, `EOSE`, `CLOSED`, and `NOTICE`
- **NIP-11**: relay metadata fetch and parsing
- **NIP-42**: relay authentication challenge handling
- **NIP-45**: event count requests and per-relay results
- **NIP-50**: search filters passed through from `Nostr.Filter`
- **NIP-77**: negentropy `NEG-OPEN`, `NEG-MSG`, and `NEG-CLOSE`

## Runtime Model

`Nostr.Client` is the public entry point. It starts and reuses
`Nostr.Client.RelaySession` processes keyed by relay URL and public key.

For a single relay, call `Nostr.Client.publish/3`,
`Nostr.Client.start_subscription/3`, or `Nostr.Client.count/4` with a relay URL
and client options.

For multi-relay workflows, start a logical `Nostr.Client.Session` with relay
specs, then call `publish_session/3`, `start_session_subscription/3`, or
`count_session/3` with the session pid.

## Secret Material

Relay sessions keep only the public key and a signer module reference. Private
keys and signing material should stay in the caller application. For NIP-42,
implement `Nostr.Client.AuthSigner` and pass the module as the `:signer` option.
