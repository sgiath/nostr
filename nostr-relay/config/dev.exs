import Config

config :nostr_relay, Nostr.Relay.Repo, database: "relay_dev.db"

config :nostr_relay, :server,
  ip: {127, 0, 0, 1},
  port: 4000

config :nostr_relay, config_path: "config/relay.toml"

config :nostr_relay, :relay_info, url: "ws://localhost:4000"

config :nostr_relay, :debug_log,
  enabled: false,
  path: "debug.log"
