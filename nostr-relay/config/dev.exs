import Config

enabled =
  case System.get_env("NOSTR_RELAY_ENABLED", "true") |> String.downcase() do
    "1" -> true
    "true" -> true
    "t" -> true
    "on" -> true
    "yes" -> true
    _ -> false
  end

port =
  case Integer.parse(System.get_env("NOSTR_RELAY_PORT", "4000")) do
    {value, _} -> value
    _ -> 4000
  end

config :nostr_relay, Nostr.Relay.Repo,
  database: "relay_dev.db",
  default_transaction_mode: :immediate

config :nostr_relay, :server,
  enabled: enabled,
  ip: {127, 0, 0, 1},
  port: port
