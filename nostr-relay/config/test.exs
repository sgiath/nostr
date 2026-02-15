import Config

config :nostr_relay, Nostr.Relay.Repo,
  database: "relay_test#{System.get_env("MIX_TEST_PARTITION")}.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :nostr_relay, :server,
  ip: {127, 0, 0, 1},
  port: 4001

config :nostr_relay, :relay_info,
  name: "Nostr Relay",
  description: "A focused, test-first Nostr relay implementation."

config :logger, level: :warning
