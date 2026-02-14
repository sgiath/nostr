# nostr-client

Elixir OTP application for communicating with Nostr relays over WebSocket.
Implements the Nostr client-relay protocol (NIP-01) using `mint_web_socket`
(functional WebSocket built on Mint). Elixir 1.19, Nix dev shell via parent flake.

## Repository Context

Part of the `niamh/` monorepo. Sibling `nostr-lib/` has low-level Nostr protocol
types (events, tags, keys). NIP specs live in `../nips/` (read-only submodule) --
these are the authoritative source for protocol behavior. The `nak/` submodule is
a reference CLI. Do not edit files in `../nips/` or `../nak/`.

## Build & Test Commands

All commands run from `nostr-client/` directory.

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

# Tests
mix test                             # all tests
mix test test/path/to_test.exs       # single file
mix test test/path/to_test.exs:42    # single test at line

# Full pre-commit check (compile + format + unused deps + credo + prettier + tests)
mix check --fix
```

`mix check` pipeline defined in `.check.exs`:
compiler -> formatter -> unused_deps -> credo -> prettier markdown -> ex_unit.

As with all libraries/apps in this repo, a task is not done until
`mix check --fix` passes successfully.

## Nostr Client-Relay Protocol (NIP-01)

Client sends JSON arrays over WebSocket:

- `["EVENT", <event>]` -- publish an event
- `["REQ", <sub_id>, <filter>, ...]` -- subscribe (max 64-char sub_id)
- `["CLOSE", <sub_id>]` -- unsubscribe

Relay responds with JSON arrays:

- `["EVENT", <sub_id>, <event>]` -- matched event
- `["OK", <event_id>, <bool>, <message>]` -- publish ack/nack
- `["EOSE", <sub_id>]` -- end of stored events
- `["CLOSED", <sub_id>, <message>]` -- server-side sub termination
- `["NOTICE", <message>]` -- human-readable info

OK/CLOSED messages use machine-readable prefixes: `duplicate`, `pow`, `blocked`,
`rate-limited`, `invalid`, `restricted`, `mute`, `error`.

## mint_web_socket Usage

Full source in `deps/mint_web_socket/`. Functional (process-less) API:

```elixir
# Connect + upgrade
{:ok, conn} = Mint.HTTP.connect(:https, "relay.example.com", 443)
{:ok, conn, ref} = Mint.WebSocket.upgrade(:wss, conn, "/", [])

# Await upgrade response, build websocket
{:ok, conn, responses} = Mint.WebSocket.stream(conn, message)
{:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, headers)

# Send frame
{:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, payload})
{:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

# Receive frame
{:ok, conn, [{:data, ^ref, data}]} = Mint.WebSocket.stream(conn, message)
{:ok, websocket, frames} = Mint.WebSocket.decode(websocket, data)
```

State is immutable -- `conn` and `websocket` must be threaded through all calls.
You must handle ping/pong yourself. All Nostr messages are `:text` frames with JSON.

### Runtime gotcha

- For relay sessions, prefer `Mint.HTTP.connect(..., protocols: [:http1])` unless HTTP/2 WS is known supported.
  Some relays negotiate HTTP/2 but reject RFC8441 WS upgrade with
  `%Mint.WebSocketError{reason: :extended_connect_disabled}`.

## Session/Auth Architecture Notes

- Session identity is `{normalized_relay_url, pubkey}` (no guest mode in library).
- Keep only `pubkey` + signer module reference in session state; never store seckey/signing material.
- Auth flow is lazy: react to `AUTH` challenge or restricted/auth-required replies, then retry blocked op once.

## Code Style

### Module Layout (enforced by Credo StrictModuleLayout)

```elixir
defmodule Nostr.Client.YourModule do
  @moduledoc """..."""

  alias Nostr.Client.Connection              # aliases first, sorted

  defstruct [:field_a, :field_b]             # struct definition

  @type t() :: %__MODULE__{...}              # typespecs

  # Public API: @doc + @spec before every public function
  @spec connect(binary(), Keyword.t()) :: {:ok, t()} | {:error, term()}
  def connect(url, opts \\ []) do ... end

  # Private helpers at the bottom
  defp helper(...), do: ...
end
```

### Formatting & Line Length

- Max line length: **120 chars** (Credo). Keep under 98 when practical.
- Standard `mix format` -- no custom `.formatter.exs` options beyond file inputs.
- Files should stay under ~500 lines; split/refactor if larger.

### Naming

- Modules: `Nostr.Client.CamelCase`.
- Functions: `snake_case`. Predicates end in `?`.
- Module attributes / variables: `snake_case`. Unused vars prefixed with `_`.
- Test modules: `Nostr.Client.YourModuleTest` in `test/nostr/client/your_module_test.exs`.

### Imports & Aliases

- Use `alias` -- never `import` entire modules (exceptions: `ExUnit.Case`, `Logger`).
- `require Logger` when using Logger macros.
- One alias per line -- no multi-alias (`alias Nostr.{A, B}`).
- Aliases sorted alphabetically (Credo AliasOrder).
- Separate `alias` and `require` blocks (Credo SeparateAliasRequire).

### Types & Specs

- `@type t()` on every struct module.
- `@spec` on every public function.
- Use `binary()` for hex-encoded strings (keys, IDs, signatures).
- Use `URI.t()` or `binary()` for relay URLs.

### Error Handling

- Return `{:ok, result}` | `{:error, reason}` for fallible operations.
- Use tagged tuples: `{:error, :timeout}`, `{:error, {:closed, reason}}`.
- Use `raise` only for programmer errors (wrong args, violated invariants).
- WebSocket/Mint errors propagate as `{:error, %Mint.WebSocketError{}}` or
  `{:error, %Mint.TransportError{}}`.

### JSON

- **Elixir 1.18+ built-in `JSON` module** -- never `Jason` or `Poison`.
- `JSON.encode!/1`, `JSON.decode!/1`, `JSON.decode/1`.

### Test Conventions

- `use ExUnit.Case, async: true` -- all tests must be async unless they need
  a real relay connection.
- Test file structure mirrors `lib/`.
- `describe "function_name/arity"` blocks grouping related tests.
- Tag integration/network tests: `@tag :integration`, `@tag :relay`.
  Exclude with `mix test --exclude integration`.
- External e2e tests use `@tag :external`, excluded by default in `test/test_helper.exs`, and should
  read relay target from `config :nostr_client, :e2e_relay_url`.
- Shared test helper modules should live in `test/support/*.ex` and be loaded via
  `elixirc_paths(:test)` in `mix.exs` (avoids `test_load_filters` warnings from `mix test`).

### GenServer / OTP Conventions

- Separate client API (public functions) from server callbacks in the same module.
- Keep `handle_*` callbacks small; delegate to private helpers.
- Use `handle_continue/2` for post-init work (e.g., connecting to relay).
- Store `conn` and `websocket` in GenServer state; update on every Mint call.

## Do Not

- Use `Jason`/`Poison` -- only built-in `JSON`.
- Edit files in `../nak/` or `../nips/` -- read-only submodules.
- Use `# credo:disable-for-this-file`.
- Block the GenServer with synchronous relay calls -- keep message handling async.
- Hardcode relay URLs in library code -- pass as configuration.

## Key Dependencies

| Package           | Purpose                           |
| ----------------- | --------------------------------- |
| `mint_web_socket` | Functional WebSocket (Mint-based) |
| `mint`            | Low-level HTTP (transitive dep)   |
| `ex_check`        | Dev: `mix check` pipeline         |
| `credo`           | Dev: linting                      |
