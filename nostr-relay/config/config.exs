import Config

config :nostr_relay,
  ecto_repos: [Nostr.Repo]

config :nostr_relay, Nostr.Repo,
  database: "relay_dev.db",
  default_transaction_mode: :immediate

import_config "#{config_env()}.exs"
