import Config

config :nostr_client,
  e2e_relay_url: System.get_env("NOSTR_E2E_RELAY_URL") || "wss://nostr.sgiath.dev/"
