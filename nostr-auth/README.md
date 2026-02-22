# Nostr Auth

`nostr-auth` is a lightweight NIP-98 adapter layer built on top of `nostr-lib`.

It handles:

- decoding `Authorization: Nostr ...` headers into signed Nostr events;
- validating NIP-98 request semantics with `Nostr.NIP98`;
- exposing replay-check hook points for app-specific storage.

It does **not** enforce pubkey policy or implement replay persistence itself.

## Core API

```elixir
request_context = %{url: "https://api.example.com/admin", method: "POST", body: raw_body}

case Nostr.Auth.validate_authorization_header(auth_header, request_context,
       nip98: [payload_policy: :require],
       replay: {MyReplayCache, ttl_seconds: 120}
     ) do
  {:ok, event} ->
    # event.pubkey is cryptographically verified
    :ok

  {:error, reason} ->
    {:error, reason}
end
```

## Plug/Phoenix helpers

```elixir
case Nostr.Auth.Plug.validate_conn(conn,
       body: raw_body,
       nip98: [payload_policy: :if_present]
     ) do
  {:ok, event} ->
    assign(conn, :nostr_event, event)

  {:error, reason} ->
    conn
    |> Plug.Conn.send_resp(401, "unauthorized: #{inspect(reason)}")
    |> Plug.Conn.halt()
end
```

## Ready-to-use Plug

```elixir
plug Nostr.Auth.Plug.RequireNip98,
  assign: :nostr_event,
  read_body: true,
  body_assign: :raw_body,
  nip98: [payload_policy: :if_present],
  replay: {MyReplayCache, ttl_seconds: 120}
```

By default this plug responds with `401` and halts when validation fails. You
can override failure behavior with `:error_status` or `:on_error`.

## Replay hook contract

Implement `Nostr.Auth.ReplayCache`:

```elixir
defmodule MyReplayCache do
  @behaviour Nostr.Auth.ReplayCache

  @impl true
  def check_and_store(event, _opts) do
    # atomically reject already-seen event IDs
    :ok
  end
end
```

## ETS Replay Cache

`Nostr.Auth.ReplayCache.ETS` is included as a ready implementation.

```elixir
# supervisor.ex
children = [
  {Nostr.Auth.ReplayCache.ETS, name: MyReplayCache, window_seconds: 3}
]

# plug pipeline
plug Nostr.Auth.Plug.RequireNip98,
  replay: {Nostr.Auth.ReplayCache.ETS, server: MyReplayCache}
```

Behavior:

- first-seen event ID is accepted and stored with first-seen monotonic time;
- duplicate event IDs are accepted while `now - first_seen < window_seconds`;
- duplicates at/after the window return `{:error, :replayed}`.
