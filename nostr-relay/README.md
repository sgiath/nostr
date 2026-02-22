# Nostr Relay

## Status

The relay is implemented and running with a pipeline-based websocket message path,
SQLite persistence, and NIP-11 metadata.

Core request lifecycle (`EVENT`, `REQ`, `COUNT`, `CLOSE`, `AUTH`) is covered by
unit tests, plus opt-in websocket integration tests.

## Implemented NIPs

The relay currently advertises these NIPs in NIP-11 metadata by default:

- `NIP-01` protocol framing, subscriptions, and event flow
- `NIP-02` contact-list compatible replaceable handling
- `NIP-04` private direct-message visibility rules
- `NIP-09` deletion events (write restrictions + read-path suppression)
- `NIP-11` relay metadata endpoint (`GET /` with `Accept: application/nostr+json`)
- `NIP-13` proof-of-work policy
- `NIP-17` private-message compatibility support
- `NIP-28` public-channel compatibility support
- `NIP-40` expiration filtering
- `NIP-42` AUTH challenge + authentication gate
- `NIP-45` COUNT queries
- `NIP-50` search filter support
- `NIP-59` gift-wrap recipient validation
- `NIP-70` protected-event publish restriction

Optional/config-gated support:

- `NIP-29` relay-based groups (advertised only when enabled)

## Implemented Relay Features

- HTTP + WebSocket entrypoint with Bandit/WebSock (`/`)
- NIP-11 relay info document with dynamic `supported_nips` and relay limits
- Per-connection websocket state and subscription tracking
- Deterministic SQLite-backed event store with Ecto migrations
- Pipeline stages for protocol parse, auth enforcement, event validation, relay policy,
  group policy, store policy, and message handling
- End-to-end `EVENT` -> `OK`, `REQ` -> `EVENT` replay + `EOSE`, `COUNT`, and `CLOSE`
- Live fan-out of newly stored events to matching active subscriptions
- Replaceable + parameterized-replaceable stale-event rejection semantics
- Authentication modes (`none`, `whitelist`, `denylist`) with timeout enforcement
- Policy checks for filter prefix length, protected events, deletion ownership,
  gift-wrap recipient tags, PoW difficulty+commitment, and optional group write checks

## Quick Start

```bash
mix deps.get
mix ecto.create
mix ecto.migrate
mix compile
mix run --no-halt
```

## Runtime Database Setup

SQLite schema is managed through Ecto migrations in `priv/repo/migrations/`.

Before first run (or after a fresh clone), prepare the DB once:

```bash
mix ecto.create
mix ecto.migrate
```

The test helper also runs these commands before `ExUnit.start/0`.

## Testing

- Default test run excludes integration tests
- Integration websocket tests are tagged `:integration`

```bash
mix test
mix test --only integration
mix check --fix
```

## Current Focus

- Storage hardening: indexes, compaction, retention, and recovery behavior
- Additional deployment and observability guidance
