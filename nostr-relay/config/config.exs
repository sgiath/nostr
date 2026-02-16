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
  supported_nips: [1, 9, 11, 42, 45, 50],
  limits: %{max_subscriptions: 100, max_filters: 100, max_limit: 10_000, min_prefix_length: 8}

config :nostr_relay, :auth,
  required: false,
  mode: :none,
  timeout_seconds: 30,
  whitelist: [],
  denylist: []

import_config "#{config_env()}.exs"
