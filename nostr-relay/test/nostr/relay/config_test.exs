defmodule Nostr.Relay.ConfigTest do
  use ExUnit.Case, async: false

  alias Nostr.Relay.Config

  @fixture_dir Path.expand("../../fixtures", __DIR__)

  setup do
    # Snapshot current app env to restore after each test
    original_relay_info = Application.get_env(:nostr_relay, :relay_info)
    original_server = Application.get_env(:nostr_relay, :server)
    original_repo = Application.get_env(:nostr_relay, Nostr.Relay.Repo)
    original_config_path = Application.get_env(:nostr_relay, :config_path)
    original_auth = Application.get_env(:nostr_relay, :auth)

    on_exit(fn ->
      Application.put_env(:nostr_relay, :relay_info, original_relay_info)
      Application.put_env(:nostr_relay, :server, original_server)
      Application.put_env(:nostr_relay, Nostr.Relay.Repo, original_repo)
      Application.put_env(:nostr_relay, :auth, original_auth)

      if original_config_path do
        Application.put_env(:nostr_relay, :config_path, original_config_path)
      else
        Application.delete_env(:nostr_relay, :config_path)
      end

      System.delete_env("NOSTR_RELAY_CONFIG")
    end)

    File.mkdir_p!(@fixture_dir)
    :ok
  end

  describe "load!/0" do
    test "returns :ok when no config path is set" do
      Application.delete_env(:nostr_relay, :config_path)
      System.delete_env("NOSTR_RELAY_CONFIG")

      assert :ok = Config.load!()
    end

    test "returns :ok when config file does not exist" do
      Application.put_env(:nostr_relay, :config_path, "/tmp/nonexistent_relay.toml")

      assert :ok = Config.load!()
    end

    test "merges relay metadata from TOML" do
      toml = """
      [relay]
      name = "Test Relay"
      description = "A test relay"
      pubkey = "aabbccdd"
      contact = "mailto:test@example.com"
      """

      path = write_fixture("relay_metadata.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      info = Application.get_env(:nostr_relay, :relay_info)
      assert Keyword.get(info, :name) == "Test Relay"
      assert Keyword.get(info, :description) == "A test relay"
      assert Keyword.get(info, :pubkey) == "aabbccdd"
      assert Keyword.get(info, :contact) == "mailto:test@example.com"
    end

    test "preserves compile-time defaults for fields not in TOML" do
      toml = """
      [relay]
      name = "Override Only Name"
      """

      path = write_fixture("partial.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      info = Application.get_env(:nostr_relay, :relay_info)
      assert Keyword.get(info, :name) == "Override Only Name"
      # software is a compile-time default, not in TOML
      assert Keyword.get(info, :software) == "nostr_relay"
    end

    test "merges server ip and port" do
      toml = """
      [server]
      ip = "192.168.1.1"
      port = 8080
      """

      path = write_fixture("server.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      server = Application.get_env(:nostr_relay, :server)
      assert Keyword.get(server, :ip) == {192, 168, 1, 1}
      assert Keyword.get(server, :port) == 8080
    end

    test "merges limits into relay_info" do
      toml = """
      [limits]
      max_subscriptions = 50
      min_prefix_length = 8
      """

      path = write_fixture("limits.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      info = Application.get_env(:nostr_relay, :relay_info)
      limits = Keyword.get(info, :limits)
      assert limits[:max_subscriptions] == 50
      assert limits[:min_prefix_length] == 8
      # Existing defaults preserved
      assert limits[:max_limit] == 10_000
    end

    test "ignores nips, software, and version from TOML" do
      toml = """
      [relay]
      name = "Override Name"
      software = "evil_relay"
      version = "9.9.9"

      [nips]
      supported = [1, 11, 42]
      """

      path = write_fixture("compile_time.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      info = Application.get_env(:nostr_relay, :relay_info)
      # Name is overridden
      assert Keyword.get(info, :name) == "Override Name"
      # These are compile-time only and must not change
      assert Keyword.get(info, :software) == "nostr_relay"
      assert Keyword.get(info, :version) == "0.1.0"
      assert Keyword.get(info, :supported_nips) == [1, 9, 11, 42, 45, 50]
    end

    test "merges database path with expansion" do
      toml = """
      [database]
      path = "~/data/relay.db"
      """

      path = write_fixture("database.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      repo = Application.get_env(:nostr_relay, Nostr.Relay.Repo)
      assert Keyword.get(repo, :database) == Path.expand("~/data/relay.db")
    end

    test "preserves repo defaults when database section absent" do
      toml = """
      [relay]
      name = "No DB Override"
      """

      path = write_fixture("no_db.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      original_db = Application.get_env(:nostr_relay, Nostr.Relay.Repo) |> Keyword.get(:database)

      assert :ok = Config.load!()

      repo = Application.get_env(:nostr_relay, Nostr.Relay.Repo)
      assert Keyword.get(repo, :database) == original_db
    end

    test "env var NOSTR_RELAY_CONFIG takes precedence over config_path" do
      toml_env = """
      [relay]
      name = "From Env Var"
      """

      toml_config = """
      [relay]
      name = "From Config Path"
      """

      env_path = write_fixture("env_var.toml", toml_env)
      config_path = write_fixture("config_path.toml", toml_config)

      Application.put_env(:nostr_relay, :config_path, config_path)
      System.put_env("NOSTR_RELAY_CONFIG", env_path)

      assert :ok = Config.load!()

      info = Application.get_env(:nostr_relay, :relay_info)
      assert Keyword.get(info, :name) == "From Env Var"
    end

    test "raises on invalid IP address" do
      toml = """
      [server]
      ip = "not-an-ip"
      """

      path = write_fixture("bad_ip.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert_raise RuntimeError, ~r/Invalid IP address/, fn ->
        Config.load!()
      end
    end

    test "returns :ok on malformed TOML" do
      path = write_fixture("bad.toml", "[[[invalid toml")
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()
    end

    test "supports IPv6 addresses" do
      toml = """
      [server]
      ip = "::1"
      """

      path = write_fixture("ipv6.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      server = Application.get_env(:nostr_relay, :server)
      assert Keyword.get(server, :ip) == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "merges auth config from TOML" do
      toml = """
      [auth]
      required = true
      mode = "whitelist"
      timeout_seconds = 60
      whitelist = ["aabb", "ccdd"]
      """

      path = write_fixture("auth.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      auth = Application.get_env(:nostr_relay, :auth)
      assert Keyword.get(auth, :required) == true
      assert Keyword.get(auth, :mode) == :whitelist
      assert Keyword.get(auth, :timeout_seconds) == 60
      assert Keyword.get(auth, :whitelist) == ["aabb", "ccdd"]
    end

    test "merges auth denylist mode from TOML" do
      toml = """
      [auth]
      required = true
      mode = "denylist"
      denylist = ["badpubkey"]
      """

      path = write_fixture("auth_deny.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      auth = Application.get_env(:nostr_relay, :auth)
      assert Keyword.get(auth, :mode) == :denylist
      assert Keyword.get(auth, :denylist) == ["badpubkey"]
    end

    test "defaults invalid auth mode to :none" do
      toml = """
      [auth]
      required = true
      mode = "bogus_mode"
      """

      path = write_fixture("auth_bad_mode.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      auth = Application.get_env(:nostr_relay, :auth)
      assert Keyword.get(auth, :mode) == :none
    end

    test "merges relay url into relay_info" do
      toml = """
      [relay]
      name = "Test Relay"
      url = "wss://relay.example.com"
      """

      path = write_fixture("relay_url.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      info = Application.get_env(:nostr_relay, :relay_info)
      assert Keyword.get(info, :url) == "wss://relay.example.com"
      assert Keyword.get(info, :name) == "Test Relay"
    end
  end

  defp write_fixture(name, content) do
    path = Path.join(@fixture_dir, name)
    File.write!(path, content)
    path
  end
end
