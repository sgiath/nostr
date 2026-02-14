defmodule Nostr.Relay.Repo do
  use Ecto.Repo,
    otp_app: :nostr_relay,
    adapter: Ecto.Adapters.SQLite3
end
