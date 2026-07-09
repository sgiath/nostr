# Multi-Relay Sessions

A multi-relay session owns one identity and a set of relay sessions. Relays can
be readable or read-write.

```elixir
{:ok, session_pid} =
  Nostr.Client.start_session(
    pubkey: MySigner.pubkey(),
    signer: MySigner,
    relays: [
      {"wss://read-relay.example", :read},
      {"wss://rw-relay-a.example", :read_write},
      {"wss://rw-relay-b.example", :read_write}
    ]
  )
```

## Managing Relays

```elixir
:ok = Nostr.Client.add_relay(session_pid, "wss://relay-c.example", :read_write)
:ok = Nostr.Client.update_relay_mode(session_pid, "wss://relay-c.example", :read)
:ok = Nostr.Client.remove_relay(session_pid, "wss://relay-c.example")
{:ok, relays} = Nostr.Client.list_relays(session_pid)
```

## Publishing

Publishing fans out to writable relays and returns a result per relay:

```elixir
{:ok, per_relay} = Nostr.Client.publish_session(session_pid, event)

# %{
#   "wss://rw-relay-a.example" => :ok,
#   "wss://rw-relay-b.example" => {:error, reason}
# }
```

## Subscribing

Multi-relay subscriptions read from all readable relays. Duplicate event IDs are
forwarded when different relays send the same event, so callers can decide how
to deduplicate.

```elixir
{:ok, sub_pid} =
  Nostr.Client.start_session_subscription(
    session_pid,
    [%Nostr.Filter{kinds: [1]}],
    consumer: self()
  )

receive do
  {:nostr_session_subscription, ^sub_pid, {:event, relay_url, event}} ->
    {relay_url, event.id}

  {:nostr_session_subscription, ^sub_pid, {:eose, relay_url}} ->
    {:relay_eose, relay_url}

  {:nostr_session_subscription, ^sub_pid, :eose_all} ->
    :all_relays_eose
end
```
