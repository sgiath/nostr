import Config

config :nostr_relay_admin, config_path: "~/.config/nostr-relay/relay.toml"

config :nostr_relay_admin, Nostr.Repo,
  database: "~/.local/share/nostr-relay/relay.db",
  pool_size: 5

config :nostr_relay_admin, NostrWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

# Configures Swoosh API Client
config :swoosh, api_client: Swoosh.ApiClient.Req

# Disable Swoosh Local Memory Storage
config :swoosh, local: false

# Do not print debug messages in production
config :logger, level: :info
