import Config

config :nostr_relay, Nostr.Relay.Repo,
  database: "relay_prod.db",
  default_transaction_mode: :immediate
