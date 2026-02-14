# Niamh Monorepo

Monorepo for Nostr-related Elixir libraries and tools. Nix flake dev environment
(Erlang 28, Elixir 1.19). Uses `direnv` + `flake.nix` for shell setup.

## Repository Layout

```
niamh/
├── nostr-lib/         # Elixir library: low-level Nostr protocol (pure lib, no OTP app)
├── nostr-client/      # Elixir OTP app: Nostr relay WebSocket client (mint_web_socket)
├── nak/               # Git submodule: fiatjaf/nak CLI (reference, do not edit)
├── nips/              # Git submodule: nostr-protocol/nips specs (reference, do not edit)
├── skills/nostr/      # nak CLI skill/reference doc
├── vanity_npub.py     # Python utility: vanity npub generator + NIP-06 BIP39 derivation
└── flake.nix          # Nix dev shell (elixir, nodejs, python3, secp256k1, prettier)
```

`nak/` and `nips/` are read-only reference submodules. The NIP specs in `nips/` are
the authoritative source for protocol behavior.

## Definition of Done

For all Elixir libraries/apps in this repo, a task is not done until
`mix check --fix` passes successfully in the relevant project directory.

## nostr-lib — Build & Test Commands

All commands run from `nostr-lib/` directory.

```bash
# Dependencies
mix deps.get

# Compile (warnings = errors in CI)
mix compile --warnings-as-errors

# Format
mix format
mix format --check-formatted        # CI check

# Lint
mix credo

# Markdown formatting (from repo root)
prettier **/*.md --check             # check
prettier **/*.md --write             # fix

# Tests
mix test                             # all tests
mix test path/to/test.exs            # single file
mix test path/to/test.exs:42         # single test at line
mix test --exclude nip05_http        # skip HTTP-dependent tests
mix test --exclude ecdh              # skip ECDH tests

# Full pre-commit check (compile + unused deps + format + credo + prettier + tests)
mix check --fix
```

`mix check` runs the full pipeline defined in `.check.exs`:
compiler -> formatter -> unused_deps -> credo -> prettier markdown -> ex_unit.

## nostr-lib — Code Style

### Module Layout (enforced by Credo StrictModuleLayout)

```elixir
defmodule Nostr.Event.YourModule do
  @moduledoc """..."""
  @moduledoc tags: [:event, :nipXX], nip: XX    # NIP metadata

  alias Nostr.Tag                                 # aliases first, sorted

  defstruct [:event, :your_field]                 # struct definition

  @type t() :: %__MODULE__{...}                   # typespecs

  # Public API: @doc + @spec before every public function
  @spec parse(Nostr.Event.t()) :: t()
  def parse(%Nostr.Event{kind: N} = event) do ... end

  @spec create(binary(), Keyword.t()) :: t()
  def create(field, opts \\ []) do ... end

  # Private helpers at the bottom
  defp helper(...), do: ...
end
```

### Formatting & Line Length

- Max line length: **120 chars** (Credo). Keep under 98 when practical.
- Standard `mix format` — no custom `.formatter.exs` options beyond file inputs.
- Files should stay under ~500 lines; split/refactor if larger.

### Naming

- Modules: `Nostr.Event.CamelCase` — match the Nostr event kind name.
- Functions: `snake_case`. Predicate fns end in `?` (e.g. `reply?/1`).
- Module attributes: `@snake_case`.
- Variables: `snake_case`. Unused vars prefixed with `_`.
- Test modules: `Nostr.Event.YourModuleTest` in `test/nostr/event/your_module_test.exs`.

### Imports & Aliases

- Use `alias` — never `import` entire modules (exceptions: `ExUnit.Case`, `Logger`).
- `require Logger` when using Logger macros.
- Aliases sorted alphabetically (Credo AliasOrder).
- No multi-alias (`alias Nostr.{A, B}`) — one alias per line (Credo MultiAlias).
- Separate `alias` and `require` blocks (Credo SeparateAliasRequire).

### Types & Specs

- `@type t()` on every struct module.
- `@spec` on every public function.
- Use `binary()` for hex-encoded strings (keys, IDs, signatures).
- Use `DateTime.t()` for timestamps (not unix integers).
- Hex key sizes: `<<_::32, _::_*8>>` for 32-byte, `<<_::64, _::_*8>>` for 64-byte.

### Error Handling

- Return `{:ok, result}` | `{:error, reason}` | `{:error, reason, event}`.
- `parse/1` returns `nil` for invalid/unrecognized input (not exceptions).
- Validation events (ZapRequest, ClientAuth) may return `{:error, reason, event}`.
- Use `raise` only for programmer errors (mismatched pubkey/seckey, wrong ID).

### JSON

- **Elixir 1.18+ built-in `JSON` module** — never `Jason` or `Poison`.
- `JSON.encode!/1`, `JSON.decode!/1`, `JSON.decode/1`.
- Custom `JSON.Encoder` protocol impls live at bottom of the struct's file.

### Tags

- Tags are `%Nostr.Tag{type: atom(), data: binary(), info: [binary()]}`.
- Build with `Nostr.Tag.create(:type, data)` or `Nostr.Tag.create(:type, data, info_list)`.
- Filter tags: `Enum.filter(tags, &(&1.type == :e))`.

### Event Module Pattern

Every event type in `lib/nostr/event/` follows:

1. `parse/1` — pattern-match on `%Nostr.Event{kind: N}`, return typed struct
2. `create/n` — build event with domain opts, call `Nostr.Event.create/2`, then `parse/1`
3. Register kind in `parser.ex` via `parse_specific/1` clause

### Test Conventions

- `use ExUnit.Case, async: true` — all tests must be async.
- `doctest ModuleName` for modules with iex examples.
- Use `Nostr.Test.Fixtures` for keypairs and event builders — never hardcode keys.
- Tag slow/external tests: `@tag :nip05_http`, `@tag :ecdh`.
- Test file structure mirrors `lib/` (e.g. `lib/nostr/nip44.ex` -> `test/nostr/nip44_test.exs`).
- `describe "function_name/arity"` blocks grouping related tests.

### Deprecation Handling

- `DirectMessage` (Kind 4) — use NIP-17 `PrivateMessage` + `Nostr.NIP17` instead.
- `Repost` (Kind 6) — use NIP-27 text note references instead.
- `RecommendRelay` (Kind 2) — use NIP-65 `RelayList` instead.
- Deprecated modules log `Logger.warning()` on parse/create but are kept for compat.

### Cross-NIP Delegation

| Concern          | Module        | Used by                          |
| ---------------- | ------------- | -------------------------------- |
| List encryption  | `Nostr.NIP51` | Bookmarks, RelayList, Mute, etc. |
| Custom emoji     | `Nostr.NIP30` | Note, Metadata, Reaction         |
| Content warnings | `Nostr.NIP36` | Note, Article                    |
| External IDs     | `Nostr.NIP39` | Metadata                         |
| Zap utilities    | `Nostr.NIP57` | ZapRequest, ZapReceipt           |

### Do Not

- Use `# credo:disable-for-this-file` (next-line disable is acceptable in Tag.parse).
- Use `Jason`/`Poison` — only built-in `JSON`.
- Hardcode test keypairs — use `Nostr.Test.Fixtures`.
- Edit files in `nak/` or `nips/` — they are read-only submodules.
- Add OTP application behavior to nostr-lib — it is a pure library.

## vanity_npub.py

Python 3 script. Runs inside a `.venv` managed by the Nix shell hook.

```bash
python vanity_npub.py npub <prefix>        # bech32 vanity search
python vanity_npub.py hex <prefix>         # hex vanity search
python vanity_npub.py bip39 <seed words>   # NIP-06 key derivation
```

## Key Dependencies (nostr-lib)

| Package         | Purpose                        |
| --------------- | ------------------------------ |
| `lib_secp256k1` | Schnorr signatures, ECDH       |
| `bechamel`      | Bech32 encoding                |
| `scrypt`        | NIP-49 key derivation          |
| `req`           | Optional: NIP-05 HTTP lookup   |
| `ex_check`      | Dev: runs `mix check` pipeline |
| `credo`         | Dev: linting                   |
