# Single Relay

Single relay calls use one relay URL, a public key, and a signer module.
`Nostr.Client` reuses the underlying relay session for the same relay and
public key.

```elixir
relay_url = "wss://relay.example"

opts = [
  pubkey: MySigner.pubkey(),
  signer: MySigner
]

{:ok, _session_pid} = Nostr.Client.get_or_start_session(relay_url, opts)
```

## Publishing

Create and sign events with `nostr_lib`, then publish through the client:

```elixir
event =
  1
  |> Nostr.Event.create(pubkey: MySigner.pubkey(), content: "hello")
  |> Nostr.Event.sign(MySigner.seckey())

:ok = Nostr.Client.publish(relay_url, event, opts)
```

The call waits for the relay `OK` response and returns `:ok` or
`{:error, reason}`.

## Subscribing

Subscriptions deliver messages to the configured `:consumer` process, defaulting
to the caller.

```elixir
{:ok, sub_pid} =
  Nostr.Client.start_subscription(
    relay_url,
    [%Nostr.Filter{kinds: [1]}],
    Keyword.put(opts, :consumer, self())
  )

receive do
  {:nostr_subscription, ^sub_pid, {:event, event}} -> event
  {:nostr_subscription, ^sub_pid, :eose} -> :end_of_stored_events
  {:nostr_subscription, ^sub_pid, {:closed, message}} -> {:closed, message}
  {:nostr_subscription, ^sub_pid, {:error, reason}} -> {:error, reason}
end
```

Stop a subscription with:

```elixir
:ok = Nostr.Client.stop_subscription(sub_pid)
```
