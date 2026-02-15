import Config

config :nostr_relay, Nostr.Relay.Repo,
  database: "relay_prod.db",
  default_transaction_mode: :immediate

config :nostr_relay, :server,
  enabled: true,
  ip: {0, 0, 0, 0},
  port: 4000
