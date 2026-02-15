# Nostr Client

Elixir OTP client for the Nostr relay protocol (NIP-01) over WebSocket.

## Client-Relay NIPs

- **NIP-01: Basic protocol flow description** - `nostr-client` implements the core WebSocket message flow (`EVENT`, `REQ`, `CLOSE`, `OK`, `EOSE`, `CLOSED`, `NOTICE`) used for publishing and subscriptions.
- **NIP-11: Relay Information Document** - `Nostr.Client.get_relay_info/2` (`Nostr.Client.RelayInfo.fetch/2`) reads relay metadata from `/.well-known/nostr.json` (`application/nostr+json`) and parses limits plus `supported_nips`.
- **NIP-42: Authentication of clients to relays** - the client handles relay `AUTH` challenges, sends signed client-auth events, and retries blocked writes after successful authentication.
- **NIP-45: Event Counts** - `nostr-client` supports `COUNT` requests on single relays and multi-relay sessions, including relay payload passthrough for `count`, optional `approximate`, and optional `hll` fields.
- **NIP-50: Search Capability** - search-enabled `REQ` filters are supported because `Nostr.Filter` includes `search` and filters are passed through unchanged to relay requests.
- **NIP-77: Negentropy Syncing** - `Nostr.Client.neg_open/5`, `neg_msg/4`, and `neg_close/3` support the `NEG-OPEN`/`NEG-MSG`/`NEG-CLOSE` lifecycle with deterministic relay/session error tuples.

## API Message Contracts

When you subscribe, events are delivered to your configured `:consumer` process.

### Single relay subscription (`Nostr.Client.start_subscription/3`)

Messages sent to `consumer`:

- `{:nostr_subscription, sub_pid, {:event, event}}`
- `{:nostr_subscription, sub_pid, :eose}`
- `{:nostr_subscription, sub_pid, {:closed, message}}`
- `{:nostr_subscription, sub_pid, {:error, reason}}`

Example:

```elixir
receive do
  {:nostr_subscription, sub_pid, {:event, event}} ->
    IO.puts("single relay event #{event.id} from #{inspect(sub_pid)}")
end
```

### Multi relay session subscription (`Nostr.Client.start_session_subscription/3`)

Messages sent to `consumer`:

- `{:nostr_session_subscription, sub_pid, {:event, relay_url, event}}`
- `{:nostr_session_subscription, sub_pid, {:eose, relay_url}}`
- `{:nostr_session_subscription, sub_pid, :eose_all}`
- `{:nostr_session_subscription, sub_pid, {:closed, relay_url, message}}`
- `{:nostr_session_subscription, sub_pid, {:error, relay_url, reason}}`
- `{:nostr_session_subscription, sub_pid, {:error, :session, reason}}`

Notes:

- Multi-relay subscriptions intentionally forward duplicate `event.id` values if they arrive from different relays.
- Use `relay_url` to build your own deduplication or relay distribution metrics.

Example:

```elixir
receive do
  {:nostr_session_subscription, sub_pid, {:event, relay_url, event}} ->
    IO.puts("event #{event.id} arrived from #{relay_url} via #{inspect(sub_pid)}")

  {:nostr_session_subscription, _sub_pid, :eose_all} ->
    IO.puts("all relays reached EOSE")
end
```

## COUNT APIs (NIP-45)

Single relay:

```elixir
{:ok, payload} =
  Nostr.Client.count(
    "wss://relay.example",
    [%Nostr.Filter{kinds: [1]}],
    pubkey: pubkey,
    signer: signer
  )

count = payload.count
approximate? = Map.get(payload, :approximate, false)
hll = Map.get(payload, :hll)
```

Multi relay fanout:

```elixir
{:ok, per_relay} =
  Nostr.Client.count_session(session_pid, [%Nostr.Filter{kinds: [1]}])

# %{relay_url => {:ok, payload} | {:error, reason}}
```

Notes:

- The library intentionally returns per-relay raw results and does not aggregate totals across relays.
- `hll` and `approximate` are transported/preserved when provided by relays.
- Client-side HLL merge/estimate utilities are not implemented yet.

## Negentropy APIs (NIP-77)

Single relay lifecycle:

```elixir
relay_url = "wss://relay.example"
opts = [pubkey: pubkey, signer: signer]

{:ok, first_turn} =
  Nostr.Client.neg_open(
    relay_url,
    "neg-sync-1",
    %Nostr.Filter{kinds: [1]},
    initial_message,
    opts
  )

{:ok, next_turn} = Nostr.Client.neg_msg(relay_url, "neg-sync-1", local_message, opts)
:ok = Nostr.Client.neg_close(relay_url, "neg-sync-1", opts)
```

Notes:

- `neg_open/5` and `neg_msg/4` wait for the next relay turn and return `{:ok, relay_message}`.
- One active lifecycle is tracked per `sub_id`; opening the same `sub_id` replaces the prior lifecycle.
- Only one outbound turn can be pending at a time for a `sub_id`; concurrent `neg_msg` calls return `{:error, :neg_msg_already_pending}`.
- Relay `NEG-ERR` is surfaced as `{:error, {:neg_err, class, reason}}` where `class` is `:blocked`, `:closed`, or `:relay`.
- Common lifecycle errors include `{:error, :not_connected}`, `{:error, :neg_not_open}`, and `{:error, {:session_stopped, reason}}`.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `nostr_client` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:nostr_client, "~> 0.1.0"}
  ]
end

## Local End-to-End Relay Tests

Use one command from the repository root to run e2e tests against a local relay:

```bash
./e2e
```

The script starts `nostr-relay`, configures `NOSTR_E2E_RELAY_URL`, runs
`mix test --include external` inside `nostr-client`, and shuts the relay down on
exit.

Manual mode:

```bash
cd nostr-relay
MIX_ENV=dev NOSTR_RELAY_ENABLED=true NOSTR_RELAY_PORT=4002 mix run --no-halt

cd ../nostr-client
NOSTR_E2E_RELAY_URL=ws://127.0.0.1:4002/ mix test --include external
```

`mix test` (without `--include external`) continues to skip all `:external` tests by
default via `nostr-client/test/test_helper.exs`.
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/nostr_client>.
