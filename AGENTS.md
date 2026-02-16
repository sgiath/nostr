# Nostr Monorepo Agent Guide

For coding agents operating in `/home/sgiath/develop/sgiath/nostr`.
Focus: reliable commands, test targeting, and style rules.

## Scope and Layout

```text
nostr/
├── nostr-lib/      # Low-level Nostr protocol library (pure lib)
├── nostr-client/   # OTP WebSocket client for relays
├── nostr-relay/    # OTP relay server implementation
├── nak/            # Read-only git submodule (reference)
├── nips/           # Read-only git submodule (authoritative specs)
├── relay-tester/   # Tooling for relay validation scenarios
└── flake.nix       # Dev shell (Elixir, Erlang, Node, Python)
```

`nips/` is the protocol authority and is read-only. `nak/` is also read-only.

Preferred setup: `direnv allow` + Nix flake shell. Toolchain target: Erlang 28, Elixir 1.19.
JSON rule: use built-in `JSON` only (never Jason/Poison).

## Definition of Done

Finish only when `mix check --fix` passes in the touched project directory.
If there are known pre-existing failures, call them out clearly in your handoff.
Root `.check.exs` order: compiler -> formatter -> unused_deps -> credo -> markdown -> ex_unit.

## Build/Lint/Test Commands

Run commands from the target project directory unless stated otherwise.

### nostr-lib

```bash
mix test test/nostr/some_module_test.exs
mix test test/nostr/some_module_test.exs:42
mix test --exclude nip05_http
mix test --exclude ecdh
mix check --fix
```

### nostr-client

```bash
mix test test/nostr/client/session_test.exs
mix test test/nostr/client/session_test.exs:42
mix test --exclude integration
mix check --fix
```

### nostr-relay

`mix test` is aliased to create/migrate test DB first.

```bash
mix test test/nostr/relay/pipeline/message_handler_test.exs
mix test test/nostr/relay/pipeline/message_handler_test.exs:42
mix test --include integration
mix check --fix
```

Repo-root utilities: `prettier **/*.md --check|--write` and
`python vanity_npub.py npub|hex|bip39 ...`.

## Code Style (All Elixir Projects)

### Module structure

- Keep strict layout: moduledoc, aliases/requires, struct, types, public funcs, private funcs.
- Put `@doc` + `@spec` on every public function.
- Keep private helpers at bottom of module.

### Imports / aliases / require

- Prefer `alias`; avoid broad `import` (exceptions: `ExUnit.Case`, sometimes `Logger`).
- Use one alias per line; no multi-alias forms.
- Keep aliases alphabetized.
- Use separate `alias` and `require` sections.
- `require Logger` before Logger macros.

### Formatting and file size

- Run `mix format`; do not hand-format against formatter output.
- Credo max line length is 120 chars; stay near 98 when practical.
- Keep files around or under 500 LOC; split when growth makes review harder.

### Naming conventions

- Modules: `Nostr.*.CamelCase`.
- Functions/vars/attrs: `snake_case`.
- Predicate functions end with `?`.
- Unused variables must be prefixed with `_`.
- Test module/file names should mirror `lib/` structure.

### Types and specs

- Add `@type t()` for every struct module.
- Add `@spec` to all public APIs.
- Use `binary()` for hex identifiers/keys/signatures.
- Prefer `DateTime.t()` in structs/APIs; convert to unix only at protocol boundaries.

### Error handling

- Prefer tagged tuples: `{:ok, value}` / `{:error, reason}`.
- Event validation may also return `{:error, reason, event}`.
- `parse/1` in event modules should return `nil` for unsupported/invalid input.
- Raise only for programmer errors or violated invariants.

### JSON and encoding

- Use `JSON.encode!/1`, `JSON.decode!/1`, `JSON.decode/1`.
- Keep custom `JSON.Encoder` impls with their owning struct modules.

### Testing conventions

- Default to `use ExUnit.Case, async: true`.
- Group by `describe "function_name/arity"`.
- Use fixtures/helpers from `test/support` or `Nostr.Test.Fixtures`; do not hardcode keypairs.
- Typical selective runs: `mix test path/to/test.exs`, `mix test path/to/test.exs:LINE`,
  `mix test --exclude integration`, `mix test --include integration`.

## Nostr-specific rules

- Follow NIP specs from `nips/` as source of truth.
- For new event kinds in `nostr-lib`: add module in `lib/nostr/event/`,
  implement `parse/1` + `create/...`, register in `lib/nostr/event/parser.ex`,
  and add mirrored tests in `test/nostr/event/`.
- Respect deprecations:
  - Kind 4 `DirectMessage` -> prefer NIP-17
  - Kind 6 `Repost` -> prefer NIP-27 references
  - Kind 2 `RecommendRelay` -> prefer NIP-65 `RelayList`

## Safety and repo hygiene

- Never edit read-only submodules: `nak/`, `nips/`.
- Do not add OTP app behavior to `nostr-lib` (it is a pure library).
- Avoid file-wide Credo disables (`# credo:disable-for-this-file`).
- Keep changes focused; do not refactor unrelated areas opportunistically.

## Cursor / Copilot rule files

Checked `.cursorrules`, `.cursor/rules/`, and `.github/copilot-instructions.md`.
No Cursor or Copilot instruction files were found in this repository.
