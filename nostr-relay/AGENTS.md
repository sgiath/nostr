# Nostr Relay Development Notes

This folder is intentionally scoped as an **implementation intent** today.

## Why this exists

- Track the upcoming relay work as a focused effort for the `nostr-relay` project.
- Preserve direction so future edits can continue quickly and consistently.

## Current Position

- No production relay code is expected in this commit.
- `README.md` documents the intended behavior and milestone sequence.
- Actual protocol modules, router, WebSocket handler, and store integration are planned, not finalized.

## Coding Constraints for Future Relay Work

- Use `nostr-lib` event/filter/message primitives as primary protocol dependencies.
- Keep modules small, tested, and aligned with existing monorepo standards.
- Prefer tracer bullet slices: connect a single end-to-end message path first, then expand.

## NIP Scope (Current Decision)

- Required for this relay: `NIP-01` (protocol framing + subscriptions/events).
- Required for relay metadata: `NIP-11` (relay info + policy fields).
- Planned staged support:
  - `NIP-09` (deletion events)
  - `NIP-13` (PoW policy)
  - `NIP-42` (AUTH)
  - `NIP-45` (COUNT)
- Scope excludes direct submodule edits outside this directory unless explicitly needed.

## Planned Milestones

1. Baseline HTTP/WebSocket bootstrap using `Bandit` and `WebSock`.
2. SQLite-backed event store + deterministic filter matching.
3. `EVENT`/`REQ`/`CLOSE`/`EOSE`/`OK` message handling.
4. Relay info and policy endpoints.
5. Tests for parser/filter/store/protocol flow.
6. Storage hardening: SQLite indexes, compaction, retention, and recovery behavior.

## Storage Baseline

- Storage implementation target: SQLite database-backed event store.
- Milestone sequencing assumes schema-driven persistence from early stages, then adds indexing and retention tuning in later hardening.

### Milestone Acceptance Checks

- M1: websocket connect and `Nostr.Message` round trips with invalid messages handled as `:error`.
- M2: filter matching reproduces NIP-01 semantics (AND inside filter, OR across filters).
- M3: `EVENT`/`OK`, `REQ`/`EVENT`/`EOSE`, `CLOSE`/`CLOSED` message lifecycle implemented end-to-end.
- M4: `NIP-11` metadata endpoint advertises exact supported NIPs and limits.

## Notes

- This file should be updated whenever milestone goals change.
- Keep implementation notes focused on relay-specific decisions; generic build notes belong in project root docs.
