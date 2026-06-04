defmodule Nostr.Repo do
  use Ecto.Repo,
    otp_app: :nostr_relay_admin,
    adapter: Ecto.Adapters.SQLite3
end
