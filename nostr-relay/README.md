# Nostr Relay (Intent Only)

## Status

- This directory is currently a **planning-and-requirements** target, not a production relay implementation yet.
- Repository intent: build a production-leaning Nostr relay using `:bandit` and shared primitives from `nostr-lib`.
- Implementation files are being prepared separately; this README is the source of truth for the relay roadmap today.

## Planned Relay Scope

- WebSocket entrypoint for NIP-01 `EVENT`, `REQ`, `CLOSE`, and related message flow.
- SQLite-backed event persistence and filter matching.
- Relay metadata/`INFO`, publishing policy, limits, and request controls.
- Monitoring, tests, and deployment docs.

## Relay-NIP Mapping (Current Intent)

- Mandatory baseline: `NIP-01` (relay protocol + filter semantics)
- Policy and relay metadata endpoint: `NIP-11`
- Optional but planned: `NIP-09` (delete requests), `NIP-13` (PoW),
  `NIP-42` (AUTH), `NIP-45` (COUNT)

## Milestone Plan

1. **M1: Protocol bootstrap**
   - HTTP `/` and websocket routes wired via Bandit/WebSock.
   - Parse/serialize all `Nostr.Message` variants used by NIP-01.
   - Unit tests for parse/serialize round trips.

2. **M2: Filter + store first slice**
   - Deterministic SQLite-backed event store with ordered `REQ` replay.
   - Implement `NIP-01` filters (`ids`, `authors`, `kinds`, `#x`, `since`, `until`, `limit`).
   - Store migration + startup bootstrap for relay database path/config.
   - `EOSE` sent exactly once per subscription request.

3. **M3: Publish / subscribe flow**
   - Accept `EVENT`, persist where possible, send `OK` and dispatch events to matching subs.
   - Handle `CLOSE` idempotently and clean up state.
   - Include relay-side reasons for failure using standardized prefixes.

4. **M4: Relay controls + info**
   - Add `NIP-11` `/` metadata response with supported NIPs and limits.
   - Add basic rate/size/write limits and consistent `NOTICE/CLOSED` policy reasons.

5. **M5: Optional protocol expansions**
   - Add `COUNT`, delete handling, `AUTH` flow, and PoW policy checks as configuration-gated features.
   - Introduce targeted integration tests per NIP.

6. **M6: Persistence hardening**
   - Add indexes and retention/cleanup policies for the SQLite event store.
   - Add operational hooks, restart behavior, and observability.

## Tracer Bullet for Next Step

Start with a single slice in M1: websocket connect + parse incoming `REQ`, persist a single event to sqlite and return it through `EVENT` + `EOSE`, then expand to `EVENT` publish + `OK`.

## Quick Start (Intended)

Planned run target:

```bash
mix deps.get
mix compile
mix run --no-halt
```

The command set above is the **target shape**; code is not yet complete.

## Current Runtime Semantics

- Each HTTP request to `/` flows through `Nostr.Relay.Web.Router`.
- A valid WebSocket request is upgraded with `Plug.Conn.upgrade_adapter/3` and handled by
  `Nostr.Relay.Web.SocketHandler`.
- `WebSock` treats `SocketHandler` as a per-connection process callback, so each incoming
  connection gets its own state struct.
- `SocketHandler` delegates frame routing to `Nostr.Relay.Web.MessageRouter` and
  per-connection state updates to `Nostr.Relay.Web.ConnectionState`.

This means the project is currently in a good shape for future relay expansion: message parsing,
connection lifecycle hooks, and per-connection subscription state are all isolated from one another.

Suggested refactors before full relay logic:

1. Add a websocket integration smoke test across two real websocket connections (tagged `:integration`).
2. Keep `SocketHandler` transport-only and add protocol logic only through
   `Nostr.Relay.Web.MessageRouter`.
3. Extend `Nostr.Relay.Web.ConnectionState` with persistence, limits, and per-connection policy
   counters as relay behavior grows.

## Contributing Notes

- Follow `nostr-lib` style guidance for all relay-related modules when implementation begins.
- Keep protocol behavior incremental (small tracer bullets), then expand to feature-complete relay behavior.

## Testing Conventions

- Unit tests and callback/router tests are part of the default test run.
- Real websocket integration coverage is tagged with `:integration` in `test/nostr/relay/web/websocket_smoke_integration_test.exs`.
- Integration tests are opt-in by default:

```bash
mix test              # excludes @tag :integration
mix test --only integration  # run websocket integration test
```

### Concurrency Invariant

- Per-connection checks already validate state isolation:
  - `test/nostr/relay/web/message_router_test.exs` validates identical subscription IDs are scoped to each state.
  - `test/nostr/relay/web/websocket_smoke_integration_test.exs` runs two websocket clients in parallel to confirm independent flows.

## Next Action

- Draft `nostr-relay` milestone tickets and wire them to test files before any runtime implementation.
