# Nostr Relay Development Notes

This folder is intentionally scoped as an **implementation intent** today.

## Why this exists

- Track the upcoming relay work as a focused effort for the `nostr-relay` project.
- Preserve direction so future edits can continue quickly and consistently.

## Current Position

- The websocket message path now runs through `Nostr.Relay.Pipeline.*`.
- `README.md` documents the intended behavior and milestone sequence.
- Core protocol handling and pipeline execution are implemented and test-covered for
  the core request slice.

## Coding Constraints for Future Relay Work

- Use `nostr-lib` event/filter/message primitives as primary protocol dependencies.
- Keep modules small, tested, and aligned with existing monorepo standards.
- Prefer tracer bullet slices: connect a single end-to-end message path first, then expand.

## NIP Scope (Current Decision)

- Required for this relay: `NIP-01` (protocol framing + subscriptions/events).
- Required for relay metadata: `NIP-11` (relay info + policy fields).
- Implemented staged support:
  - `NIP-42` (AUTH) **(Implemented.)**
  - `NIP-45` (COUNT) **(Implemented.)**
- Planned staged support:
  - `NIP-09` (deletion events)
  - `NIP-13` (PoW policy)
- Scope excludes direct submodule edits outside this directory unless explicitly needed.

## Planned Milestones

1. Baseline HTTP/WebSocket bootstrap using `Bandit` and `WebSock`.
2. SQLite-backed event store + deterministic filter matching.
3. `EVENT`/`REQ`/`CLOSE`/`EOSE`/`OK` message handling. **(Implemented.)**
4. Relay controls + info endpoints. **(Implemented for NIP-11 metadata and limits.)**
5. Tests for parser/filter/store/protocol flow.
6. Storage hardening: SQLite indexes, compaction, retention, and recovery behavior.

## Pipeline Status

- Stage engine: `Nostr.Relay.Pipeline.Engine`
- Shared context: `Nostr.Relay.Pipeline.Context`
- Stage behaviour: `Nostr.Relay.Pipeline.Stage`
- Handler stages:
  - `Nostr.Relay.Pipeline.Stages.ProtocolValidator`
  - `Nostr.Relay.Pipeline.Stages.AuthEnforcer`
  - `Nostr.Relay.Pipeline.Stages.MessageValidator`
  - `Nostr.Relay.Pipeline.Stages.RelayPolicyValidator`
  - `Nostr.Relay.Pipeline.Stages.MessageHandler`
  - `Nostr.Relay.Pipeline.Stages.StorePolicy`

Current default stage order is protocol parse -> auth enforcer -> message validation ->
relay policy -> message handling -> store policy.

## Storage Baseline

- Storage implementation target: SQLite database-backed event store.
- Milestone sequencing assumes schema-driven persistence from early stages, then adds indexing and retention tuning in later hardening.

### Milestone Acceptance Checks

- M1: websocket connect and `Nostr.Message` round trips with invalid messages handled as `:error`.
- M2: pipeline stages execute with explicit `{:ok, context}` / `{:error, reason, context}` contracts.
- M3: filter matching reproduces NIP-01 semantics (AND inside filter, OR across filters).
- M4: `EVENT`/`OK`, `REQ`/`EVENT`/`EOSE`, `CLOSE`/`CLOSED` message lifecycle implemented end-to-end for core path.
- M5: `NIP-11` metadata endpoint advertises exact supported NIPs and limits. **(Implemented.)**

## Notes

- This file should be updated whenever milestone goals change.
- Keep implementation notes focused on relay-specific decisions; generic build notes belong in project root docs.

## Non-Obvious Learnings

- `@moduletag :integration` tests are now opt-in in `nostr-relay` by default:
  `test_helper.exs` runs `ExUnit.configure(exclude: [integration: true])` before `ExUnit.start/0`.
- WebSocket smoke test setup using `Mint.WebSocket` is sensitive to request handling shape:
  call `WebSocket.upgrade/4` first, then process the initial upgrade message and only create
  the websocket with `WebSocket.new/4` after matching the `101` response headers.
- `WebSocket.stream/2` can return `:unknown` during integration handshake/message flow,
  so test helpers should retry instead of treating it as terminal failure.
- `ProtocolValidator.safe_parse` and `try_unverified_event` both call `Parser.parse`,
  so a crash in `Parser.parse` defeats the fallback path. Fixes to parsing robustness
  must go in `nostr-lib`'s `Parser.parse` itself, not in the relay's rescue wrappers.
- `Event.compute_id` → `serialize` → `DateTime.to_unix` crashes on nil `created_at`.
  Both `Validator.valid?` (nostr-lib) and `EventValidator.validate_event` (nostr-relay)
  call `compute_id` independently — both need nil guards, fixing one isn't enough.
- JSON scientific notation (e.g. `1e+10`) decodes to Elixir float, not integer.
  `DateTime.from_unix!/1` only accepts integers, so this is a distinct crash vector
  from out-of-range integers. Any unix timestamp parsing must handle both cases.
- `mix check --fix` in nostr-relay has pre-existing Credo failures (~15 readability
  issues, 1 cyclomatic complexity) that predate current work. Tests pass independently.
