import Config

config :nostr_relay, Nostr.Relay.Repo, database: "relay_dev.db"

config :nostr_relay, :server,
  ip: {127, 0, 0, 1},
  port: 4000

config :nostr_relay, :relay_info,
  name: "Nostr Relay",
  description: "A focused, test-first Nostr relay implementation."
