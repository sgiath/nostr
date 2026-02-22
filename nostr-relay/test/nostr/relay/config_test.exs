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
    original_nip29 = Application.get_env(:nostr_relay, :nip29)
    original_relay_identity = Application.get_env(:nostr_relay, :relay_identity)
    original_relay_policy = Application.get_env(:nostr_relay, :relay_policy)

    on_exit(fn ->
      Application.put_env(:nostr_relay, :relay_info, original_relay_info)
      Application.put_env(:nostr_relay, :server, original_server)
      Application.put_env(:nostr_relay, Nostr.Relay.Repo, original_repo)
      Application.put_env(:nostr_relay, :auth, original_auth)
      Application.put_env(:nostr_relay, :nip29, original_nip29)
      Application.put_env(:nostr_relay, :relay_identity, original_relay_identity)
      Application.put_env(:nostr_relay, :relay_policy, original_relay_policy)

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
      self_pub = "ddeeff00"
      self_sec = "1122"
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

      identity = Application.get_env(:nostr_relay, :relay_identity)
      assert Keyword.get(identity, :self_pub) == "ddeeff00"
      assert Keyword.get(identity, :self_sec) == "1122"
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
      assert Keyword.get(info, :software) == "https://github.com/sgiath/nostr"
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

    test "merges limitation into relay_info" do
      toml = """
      [limitation]
      max_message_length = 16384
      max_subscriptions = 50
      min_pow_difficulty = 20
      """

      path = write_fixture("limitation_basic.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      info = Application.get_env(:nostr_relay, :relay_info)
      limitation = Keyword.get(info, :limitation)

      assert limitation[:max_message_length] == 16_384
      assert limitation[:max_subscriptions] == 50
      assert limitation[:min_pow_difficulty] == 20
      # Existing defaults preserved
      assert limitation[:max_limit] == 10_000
      assert limitation[:max_subid_length] == 100
      assert limitation[:max_event_tags] == 100
      assert limitation[:max_content_length] == 8_192
      assert limitation[:payment_required] == false
      assert limitation[:restricted_writes] == false
      assert limitation[:created_at_lower_limit] == 31_536_000
      assert limitation[:created_at_upper_limit] == 900
      assert limitation[:default_limit] == 500
      assert Keyword.get(info, :limits) == nil

      server = Application.get_env(:nostr_relay, :server)
      websocket_options = Keyword.get(server, :websocket_options, [])
      assert Keyword.get(websocket_options, :max_frame_size) == 16_384
    end

    test "merges relay supported_nips and software/version from TOML" do
      toml = """
      [relay]
      name = "Override Name"
      software = "evil_relay"
      version = "9.9.9"
      supported_nips = [42, 11, 70, 42]
      """

      path = write_fixture("compile_time.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      info = Application.get_env(:nostr_relay, :relay_info)
      # Name is overridden
      assert Keyword.get(info, :name) == "Override Name"
      assert Keyword.get(info, :supported_nips) == [11, 42, 70]
      assert Keyword.get(info, :software) == "evil_relay"
      assert Keyword.get(info, :version) == "9.9.9"
    end

    test "merges NIP-11 optional metadata fields from TOML" do
      toml = """
      [relay]
      banner = "https://relay.example.com/banner.png"
      icon = "https://relay.example.com/icon.png"
      privacy_policy = "https://relay.example.com/privacy.txt"
      terms_of_service = "https://relay.example.com/tos.txt"
      payments_url = "https://relay.example.com/payments"

      [relay.fees]

      [[relay.fees.admission]]
      amount = 1000
      unit = "msats"
      """

      path = write_fixture("relay_nip11_fields.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      info = Application.get_env(:nostr_relay, :relay_info)
      assert Keyword.get(info, :banner) == "https://relay.example.com/banner.png"
      assert Keyword.get(info, :icon) == "https://relay.example.com/icon.png"
      assert Keyword.get(info, :terms_of_service) == "https://relay.example.com/tos.txt"
      assert Keyword.get(info, :payments_url) == "https://relay.example.com/payments"
      assert Keyword.get(info, :fees) == %{admission: [%{amount: 1000, unit: "msats"}]}
      assert Keyword.get(info, :privacy_policy) == nil
    end

    test "merges NIP-11 limitation from TOML" do
      toml = """
      [limitation]
      max_subscriptions = 50
      min_pow_difficulty = 10
      auth_required = true
      payment_required = true
      created_at_lower_limit = 30
      min_prefix_length = 8
      """

      path = write_fixture("limitation.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      info = Application.get_env(:nostr_relay, :relay_info)
      limitation = Keyword.get(info, :limitation)

      assert limitation[:max_subscriptions] == 50
      assert limitation[:min_pow_difficulty] == 10
      assert limitation[:auth_required] == nil
      assert limitation[:payment_required] == true
      assert limitation[:created_at_lower_limit] == 30
      assert limitation[:min_prefix_length] == nil
      assert Keyword.get(info, :limits) == nil
    end

    test "merges relay_policy from TOML" do
      toml = """
      [relay_policy]
      min_prefix_length = 4
      """

      path = write_fixture("relay_policy.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      relay_policy = Application.get_env(:nostr_relay, :relay_policy)
      assert Keyword.get(relay_policy, :min_prefix_length) == 4
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

    test "merges nip29 config from TOML" do
      toml = """
      [nip29]
      enabled = true
      allow_unmanaged_groups = false

      [nip29.optional_checks]
      enforce_group_id_charset = true

      [nip29.roles]
      admin = ["put_user", "remove_user"]
      """

      path = write_fixture("nip29.toml", toml)
      Application.put_env(:nostr_relay, :config_path, path)

      assert :ok = Config.load!()

      nip29 = Application.get_env(:nostr_relay, :nip29)
      assert Keyword.get(nip29, :enabled) == true
      assert Keyword.get(nip29, :allow_unmanaged_groups) == false

      checks = Keyword.get(nip29, :optional_checks)
      assert checks[:enforce_group_id_charset] == true

      roles = Keyword.get(nip29, :roles)
      assert roles["admin"] == [:put_user, :remove_user]
    end
  end

  defp write_fixture(name, content) do
    path = Path.join(@fixture_dir, name)
    File.write!(path, content)
    path
  end
end
