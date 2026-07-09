# Count and Negentropy

## Event Counts

Use NIP-45 `COUNT` requests to ask a relay how many events match a filter.

```elixir
{:ok, payload} =
  Nostr.Client.count(
    "wss://relay.example",
    [%Nostr.Filter{kinds: [1]}],
    pubkey: pubkey,
    signer: signer
  )

payload.count
Map.get(payload, :approximate, false)
Map.get(payload, :hll)
```

For multi-relay sessions, results are returned per relay:

```elixir
{:ok, per_relay} =
  Nostr.Client.count_session(session_pid, [%Nostr.Filter{kinds: [1]}])
```

`Nostr.Client.count_session_hll/3` can aggregate relay HyperLogLog payloads for
a single filter when relays return compatible NIP-45 data.

## Negentropy

NIP-77 negentropy lifecycles are scoped by relay and subscription ID.

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

Only one outbound negentropy turn can be pending for a subscription ID at a time.
Relay `NEG-ERR` responses are returned as
`{:error, {:neg_err, class, reason}}`.
