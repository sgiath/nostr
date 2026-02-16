import Config

config :nostr_relay, Nostr.Relay.Repo, database: "~/.local/share/nostr-relay/relay.db"

config :nostr_relay, :server,
  ip: {0, 0, 0, 0},
  port: 4000

config :nostr_relay, config_path: "~/.config/nostr-relay/relay.toml"

config :nostr_relay, :relay_info,
  name: "Nostr Relay",
  description: "A focused, test-first Nostr relay implementation."
