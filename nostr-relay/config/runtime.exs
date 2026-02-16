import Config

if config_env() != :test do
  Nostr.Relay.Config.load!()
  Nostr.Relay.Config.ensure_database_path!()
end
