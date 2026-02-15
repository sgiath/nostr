import Config

if config_env() != :test do
  server_config = Application.get_env(:nostr_relay, :server, [])

  server_config =
    case System.get_env("PORT") do
      nil -> server_config
      port -> Keyword.put(server_config, :port, String.to_integer(port))
    end

  config :nostr_relay, :server, server_config
end
