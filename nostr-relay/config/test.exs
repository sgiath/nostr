import Config

config :nostr_relay, Nostr.Relay.Repo,
  database: "relay_test.db",
  default_transaction_mode: :immediate
