defmodule Nostr.Admin.Config do
  @moduledoc """
  Loads external TOML configuration and merges it into admin application env.

  Resolution order for config file path:

  1. `NOSTR_RELAY_CONFIG` environment variable
  2. Application env `:nostr_relay_admin, :config_path`
  3. No file - log warning and keep compile-time defaults
  """

  require Logger

  @admin_keys [:host, :scheme, :ip, :port]

  @doc """
  Loads TOML config and applies admin/database runtime overrides.
  """
  @spec load!() :: :ok
  def load! do
    case resolve_path() do
      nil ->
        Logger.warning("[config] No TOML config file configured; using defaults")
        :ok

      path ->
        expanded = Path.expand(path)

        if File.exists?(expanded) do
          apply_toml!(expanded)
        else
          Logger.warning("[config] TOML config not found at #{expanded}; using defaults")
          :ok
        end
    end
  end

  @doc """
  Expands the configured Repo database path and ensures its parent directory exists.
  """
  @spec ensure_database_path!() :: :ok
  def ensure_database_path! do
    current = Application.get_env(:nostr_relay_admin, Nostr.Repo, [])

    case Keyword.get(current, :database) do
      nil -> :ok
      path -> set_database_path(path)
    end
  end

  @spec resolve_path() :: String.t() | nil
  defp resolve_path do
    System.get_env("NOSTR_RELAY_CONFIG") ||
      Application.get_env(:nostr_relay_admin, :config_path)
  end

  @spec apply_toml!(String.t()) :: :ok
  defp apply_toml!(path) do
    Logger.info("[config] Loading TOML config from #{path}")
    config_dir = Path.dirname(path)

    case Toml.decode_file(path, keys: :atoms) do
      {:ok, toml} ->
        merge_database(toml, config_dir)
        merge_admin(toml)
        :ok

      {:error, reason} ->
        Logger.error("[config] Failed to parse #{path}: #{inspect(reason)}")
        :ok
    end
  end

  defp merge_database(%{database: %{path: db_path}}, config_dir) when is_binary(db_path) do
    set_database_path(db_path, config_dir)
  end

  defp merge_database(_toml, _config_dir), do: :ok

  defp merge_admin(%{admin: admin}) when is_map(admin) do
    endpoint = Application.get_env(:nostr_relay_admin, NostrWeb.Endpoint, [])
    admin_overrides = Map.take(admin, @admin_keys)

    new_http =
      endpoint
      |> Keyword.get(:http, [])
      |> maybe_put_http_ip(admin_overrides)
      |> maybe_put_http_port(admin_overrides)

    new_url =
      endpoint
      |> Keyword.get(:url, [])
      |> maybe_put_url_host(admin_overrides)
      |> maybe_put_url_scheme(admin_overrides)
      |> maybe_put_url_port(admin_overrides)

    endpoint
    |> Keyword.put(:http, new_http)
    |> Keyword.put(:url, new_url)
    |> then(&Application.put_env(:nostr_relay_admin, NostrWeb.Endpoint, &1))
  end

  defp merge_admin(_toml), do: :ok

  defp set_database_path(path, base_dir \\ nil) do
    expanded = expand_path(path, base_dir)

    expanded
    |> Path.dirname()
    |> File.mkdir_p!()

    current = Application.get_env(:nostr_relay_admin, Nostr.Repo, [])
    Application.put_env(:nostr_relay_admin, Nostr.Repo, Keyword.put(current, :database, expanded))
  end

  defp maybe_put_http_ip(http, %{ip: ip_string}) when is_binary(ip_string) do
    Keyword.put(http, :ip, parse_ip!(ip_string))
  end

  defp maybe_put_http_ip(http, _admin), do: http

  defp maybe_put_http_port(http, %{port: port}) when is_integer(port) and port > 0 do
    Keyword.put(http, :port, port)
  end

  defp maybe_put_http_port(http, _admin), do: http

  defp maybe_put_url_host(url, %{host: host}) when is_binary(host) and host != "" do
    Keyword.put(url, :host, host)
  end

  defp maybe_put_url_host(url, _admin), do: url

  defp maybe_put_url_scheme(url, %{scheme: scheme}) when is_binary(scheme) and scheme != "" do
    Keyword.put(url, :scheme, scheme)
  end

  defp maybe_put_url_scheme(url, _admin), do: url

  defp maybe_put_url_port(url, %{port: port}) when is_integer(port) and port > 0 do
    Keyword.put(url, :port, port)
  end

  defp maybe_put_url_port(url, _admin), do: url

  defp expand_path(path, nil), do: Path.expand(path)
  defp expand_path(path, base_dir), do: Path.expand(path, base_dir)

  @spec parse_ip!(String.t()) :: :inet.ip_address()
  defp parse_ip!(ip_string) do
    charlist = String.to_charlist(ip_string)

    case :inet.parse_address(charlist) do
      {:ok, addr} -> addr
      {:error, _} -> raise "Invalid IP address in admin config: #{ip_string}"
    end
  end
end
