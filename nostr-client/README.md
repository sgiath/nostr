# Nostr Client

Elixir OTP client for the Nostr relay protocol (NIP-01) over WebSocket.

## Client-Relay NIPs

From `../nips/`, these are the NIPs that directly affect client-relay communication for this project.

### Implemented

- **NIP-01: Basic protocol flow description** - `nostr-client` implements the core WebSocket message flow (`EVENT`, `REQ`, `CLOSE`, `OK`, `EOSE`, `CLOSED`, `NOTICE`) used for publishing and subscriptions.
- **NIP-45: Event Counts** - `nostr-client` supports `COUNT` requests on single relays and multi-relay sessions, including relay payload passthrough for `count`, optional `approximate`, and optional `hll` fields.
- **NIP-42: Authentication of clients to relays** - the client handles relay `AUTH` challenges, sends signed client-auth events, and retries blocked writes after successful authentication.
- **NIP-50: Search Capability** - search-enabled `REQ` filters are supported because `Nostr.Filter` includes `search` and filters are passed through unchanged to relay requests.

### Not implemented

- **NIP-11: Relay Information Document** - the client does not fetch relay HTTP metadata (`application/nostr+json`) to discover relay limits or `supported_nips`.
- **NIP-77: Negentropy Syncing** - the `NEG-OPEN`/`NEG-MSG`/`NEG-CLOSE` reconciliation protocol is not implemented.

Note: NIP-12 and NIP-20 are marked as moved into NIP-01 in `../nips/`, so they are treated as covered by the NIP-01 implementation above.

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

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `nostr_client` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:nostr_client, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/nostr_client>.
