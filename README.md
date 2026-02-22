# Nostr Monorepo

This repository contains multiple Elixir projects for building Nostr clients, relays, and supporting tooling.

## Libraries and Apps

- `nostr-lib` - Low-level Nostr protocol library (events, tags, signing, parsing, encoding, NIP helpers).
- `nostr-client` - OTP WebSocket client for talking to Nostr relays (`EVENT`, `REQ`, `COUNT`, `AUTH`, etc.).
- `nostr-relay` - OTP relay server implementation with HTTP/WebSocket entrypoint and SQLite-backed persistence.
- `nostr-auth` - NIP-98 HTTP authorization adapter layer (header parsing, request validation, Plug helpers).
