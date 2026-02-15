import Config

config :nostr_relay,
  ecto_repos: [Nostr.Relay.Repo]

config :nostr_relay, :server,
  scheme: :http,
  websocket_options: [compress: false, max_frame_size: 8_000_000]

config :nostr_relay, Nostr.Relay.Repo,
  database: "relay_dev.db",
  default_transaction_mode: :immediate

import_config "#{config_env()}.exs"
