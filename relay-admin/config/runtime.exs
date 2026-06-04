import Config

if config_env() != :test do
  Nostr.Admin.Config.load!()
  Nostr.Admin.Config.ensure_database_path!()
end

if System.get_env("PHX_SERVER") do
  config :nostr_relay_admin, NostrWeb.Endpoint, server: true
end

if config_env() == :prod do
  repo_config = Application.get_env(:nostr_relay_admin, Nostr.Repo, [])
  endpoint_config = Application.get_env(:nostr_relay_admin, NostrWeb.Endpoint, [])
  endpoint_http = Keyword.get(endpoint_config, :http, [])
  endpoint_url = Keyword.get(endpoint_config, :url, [])

  bind_ip =
    Keyword.get(endpoint_http, :ip) ||
      raise """
      [admin].ip is missing in relay TOML config.
      """

  bind_port =
    Keyword.get(endpoint_http, :port) ||
      raise """
      [admin].port is missing in relay TOML config.
      """

  host =
    Keyword.get(endpoint_url, :host) ||
      raise """
      [admin].host is missing in relay TOML config.
      """

  scheme =
    Keyword.get(endpoint_url, :scheme) ||
      raise """
      [admin].scheme is missing in relay TOML config.
      """

  url_port =
    Keyword.get(endpoint_url, :port) ||
      if(scheme == "https", do: 443, else: 80)


  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :nostr_relay_admin, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :nostr_relay_admin, NostrWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    http: [
      ip: bind_ip,
      port: bind_port
    ],
    secret_key_base: secret_key_base
end
