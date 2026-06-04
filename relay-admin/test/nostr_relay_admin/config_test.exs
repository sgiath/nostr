defmodule Nostr.Admin.ConfigTest do
  use ExUnit.Case, async: false

  alias Nostr.Admin.Config

  setup do
    original_repo = Application.get_env(:nostr_relay_admin, Nostr.Repo)
    original_endpoint = Application.get_env(:nostr_relay_admin, NostrWeb.Endpoint)
    original_config_path = Application.get_env(:nostr_relay_admin, :config_path)

    on_exit(fn ->
      Application.put_env(:nostr_relay_admin, Nostr.Repo, original_repo)
      Application.put_env(:nostr_relay_admin, NostrWeb.Endpoint, original_endpoint)

      if original_config_path do
        Application.put_env(:nostr_relay_admin, :config_path, original_config_path)
      else
        Application.delete_env(:nostr_relay_admin, :config_path)
      end

      System.delete_env("NOSTR_RELAY_CONFIG")
    end)

    :ok
  end

  describe "load!/0" do
    test "returns :ok when no config path is set" do
      Application.delete_env(:nostr_relay_admin, :config_path)
      System.delete_env("NOSTR_RELAY_CONFIG")

      assert :ok = Config.load!()
    end

    test "merges database and admin endpoint settings" do
      toml = """
      [database]
      path = "./relay_shared.db"

      [admin]
      ip = "192.168.10.2"
      port = 4100
      host = "admin.local"
      scheme = "http"
      """

      path = write_fixture("admin.toml", toml)
      Application.put_env(:nostr_relay_admin, :config_path, path)

      assert :ok = Config.load!()

      repo = Application.get_env(:nostr_relay_admin, Nostr.Repo)
      assert Keyword.get(repo, :database) == Path.expand("./relay_shared.db", Path.dirname(path))

      endpoint = Application.get_env(:nostr_relay_admin, NostrWeb.Endpoint)
      http = Keyword.get(endpoint, :http, [])
      url = Keyword.get(endpoint, :url, [])

      assert Keyword.get(http, :ip) == {192, 168, 10, 2}
      assert Keyword.get(http, :port) == 4100
      assert Keyword.get(url, :host) == "admin.local"
      assert Keyword.get(url, :scheme) == "http"
      assert Keyword.get(url, :port) == 4100
    end

    test "env var NOSTR_RELAY_CONFIG takes precedence over config_path" do
      toml_env = """
      [admin]
      host = "from-env"
      """

      toml_config = """
      [admin]
      host = "from-config"
      """

      env_path = write_fixture("admin_env.toml", toml_env)
      config_path = write_fixture("admin_config_path.toml", toml_config)

      Application.put_env(:nostr_relay_admin, :config_path, config_path)
      System.put_env("NOSTR_RELAY_CONFIG", env_path)

      assert :ok = Config.load!()

      endpoint = Application.get_env(:nostr_relay_admin, NostrWeb.Endpoint)
      url = Keyword.get(endpoint, :url, [])
      assert Keyword.get(url, :host) == "from-env"
    end

    test "raises on invalid admin ip" do
      toml = """
      [admin]
      ip = "not-an-ip"
      """

      path = write_fixture("admin_bad_ip.toml", toml)
      Application.put_env(:nostr_relay_admin, :config_path, path)

      assert_raise RuntimeError, ~r/Invalid IP address in admin config/, fn ->
        Config.load!()
      end
    end
  end

  defp write_fixture(name, content) do
    fixture_dir =
      Path.join(System.tmp_dir!(), "nostr_admin_config_#{System.unique_integer([:positive])}")

    File.mkdir_p!(fixture_dir)

    path = Path.join(fixture_dir, name)
    File.write!(path, content)
    path
  end
end
