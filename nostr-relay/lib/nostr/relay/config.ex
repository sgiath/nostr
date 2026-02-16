defmodule Nostr.Relay.Config do
  @moduledoc """
  Loads external TOML configuration and merges it into application env.

  Resolution order for config file path:

  1. `NOSTR_RELAY_CONFIG` environment variable
  2. Application env `:nostr_relay, :config_path` (set per-environment in dev/prod.exs)
  3. No file — log warning, keep compile-time defaults
  """

  require Logger

  @relay_keys [:name, :description, :pubkey, :contact, :url]
  @limit_keys [:max_subscriptions, :max_filters, :max_limit, :min_prefix_length]
  @auth_keys [:required, :mode, :timeout_seconds, :whitelist, :denylist]

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

  @spec resolve_path() :: String.t() | nil
  defp resolve_path do
    System.get_env("NOSTR_RELAY_CONFIG") ||
      Application.get_env(:nostr_relay, :config_path)
  end

  @spec apply_toml!(String.t()) :: :ok
  defp apply_toml!(path) do
    Logger.info("[config] Loading TOML config from #{path}")

    case Toml.decode_file(path, keys: :atoms) do
      {:ok, toml} ->
        merge_relay_info(toml)
        merge_server(toml)
        merge_database(toml)
        merge_limits(toml)
        merge_auth(toml)
        :ok

      {:error, reason} ->
        Logger.error("[config] Failed to parse #{path}: #{inspect(reason)}")
        :ok
    end
  end

  defp merge_relay_info(%{relay: relay}) when is_map(relay) do
    current = Application.get_env(:nostr_relay, :relay_info, [])

    overrides =
      relay
      |> Map.take(@relay_keys)
      |> Enum.to_list()

    Application.put_env(:nostr_relay, :relay_info, Keyword.merge(current, overrides))
  end

  defp merge_relay_info(_toml), do: :ok

  defp merge_server(%{server: server}) when is_map(server) do
    current = Application.get_env(:nostr_relay, :server, [])

    overrides =
      []
      |> maybe_put(:ip, server)
      |> maybe_put(:port, server)

    Application.put_env(:nostr_relay, :server, Keyword.merge(current, overrides))
  end

  defp merge_server(_toml), do: :ok

  defp merge_database(%{database: %{path: db_path}}) when is_binary(db_path) do
    set_database_path(db_path)
  end

  defp merge_database(_toml), do: :ok

  @doc """
  Expands `~` in the configured Repo database path and ensures its parent
  directory exists. Called after TOML merge so both compile-time and TOML
  paths are handled.
  """
  @spec ensure_database_path!() :: :ok
  def ensure_database_path! do
    current = Application.get_env(:nostr_relay, Nostr.Relay.Repo, [])

    case Keyword.get(current, :database) do
      nil -> :ok
      path -> set_database_path(path)
    end
  end

  defp set_database_path(path) do
    expanded = Path.expand(path)

    expanded
    |> Path.dirname()
    |> File.mkdir_p!()

    current = Application.get_env(:nostr_relay, Nostr.Relay.Repo, [])
    Application.put_env(:nostr_relay, Nostr.Relay.Repo, Keyword.put(current, :database, expanded))
  end

  defp merge_limits(%{limits: limits}) when is_map(limits) do
    current = Application.get_env(:nostr_relay, :relay_info, [])
    current_limits = Keyword.get(current, :limits, %{})
    new_limits = Map.merge(current_limits, Map.take(limits, @limit_keys))
    Application.put_env(:nostr_relay, :relay_info, Keyword.put(current, :limits, new_limits))
  end

  defp merge_limits(_toml), do: :ok

  defp merge_auth(%{auth: auth}) when is_map(auth) do
    current = Application.get_env(:nostr_relay, :auth, [])

    overrides =
      auth
      |> Map.take(@auth_keys)
      |> normalize_auth_mode()
      |> Enum.to_list()

    Application.put_env(:nostr_relay, :auth, Keyword.merge(current, overrides))
  end

  defp merge_auth(_toml), do: :ok

  defp normalize_auth_mode(%{mode: mode} = auth) when is_binary(mode) do
    Map.put(auth, :mode, String.to_existing_atom(mode))
  rescue
    ArgumentError -> Map.put(auth, :mode, :none)
  end

  defp normalize_auth_mode(auth), do: auth

  defp maybe_put(overrides, :ip, %{ip: ip_string}) when is_binary(ip_string) do
    [{:ip, parse_ip!(ip_string)} | overrides]
  end

  defp maybe_put(overrides, :port, %{port: port}) when is_integer(port) do
    [{:port, port} | overrides]
  end

  defp maybe_put(overrides, _key, _server), do: overrides

  @spec parse_ip!(String.t()) :: :inet.ip_address()
  defp parse_ip!(ip_string) do
    charlist = String.to_charlist(ip_string)

    case :inet.parse_address(charlist) do
      {:ok, addr} -> addr
      {:error, _} -> raise "Invalid IP address in relay config: #{ip_string}"
    end
  end
end
