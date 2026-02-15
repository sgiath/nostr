import Config

config :nostr_relay,
  ecto_repos: [Nostr.Relay.Repo]

config :nostr_relay, :server,
  scheme: :http,
  websocket_options: [compress: false, max_frame_size: 8_000_000]

config :nostr_relay, Nostr.Relay.Repo, default_transaction_mode: :immediate

config :nostr_relay, :relay_info,
  software: "nostr_relay",
  version: "0.1.0",
  supported_nips: [1, 11, 45],
  limits: %{max_subscriptions: 100, max_filters: 100, max_limit: 10_000}

import_config "#{config_env()}.exs"
