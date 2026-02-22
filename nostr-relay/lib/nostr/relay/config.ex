defmodule Nostr.Relay.Config do
  @moduledoc """
  Loads external TOML configuration and merges it into application env.

  Resolution order for config file path:

  1. `NOSTR_RELAY_CONFIG` environment variable
  2. Application env `:nostr_relay, :config_path` (set per-environment in dev/prod.exs)
  3. No file — log warning, keep compile-time defaults
  """

  require Logger

  @relay_info_keys [:name, :description, :pubkey, :contact, :url, :supported_nips]
  @relay_identity_keys [:self_pub, :self_sec]
  @limit_keys [
    :max_subscriptions,
    :max_filters,
    :max_limit,
    :min_prefix_length,
    :min_pow_difficulty
  ]
  @auth_keys [:required, :mode, :timeout_seconds, :whitelist, :denylist]
  @nip29_keys [
    :enabled,
    :allow_unmanaged_groups,
    :publish_group_members,
    :publish_group_roles,
    :optional_checks,
    :joins,
    :roles
  ]
  @capability_names %{
    "put_user" => :put_user,
    "remove_user" => :remove_user,
    "edit_metadata" => :edit_metadata,
    "delete_event" => :delete_event,
    "create_invite" => :create_invite,
    "delete_group" => :delete_group,
    "create_group" => :create_group,
    "moderate" => :moderate
  }

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
        merge_relay_identity(toml)
        merge_server(toml)
        merge_database(toml)
        merge_limits(toml)
        merge_auth(toml)
        merge_nip29(toml)
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
      |> Map.take(@relay_info_keys)
      |> normalize_relay_info()
      |> Enum.to_list()

    Application.put_env(:nostr_relay, :relay_info, Keyword.merge(current, overrides))
  end

  defp merge_relay_info(_toml), do: :ok

  defp normalize_relay_info(%{supported_nips: supported_nips} = relay)
       when is_list(supported_nips) do
    Map.put(relay, :supported_nips, normalize_supported_nips(supported_nips))
  end

  defp normalize_relay_info(%{supported_nips: _invalid} = relay) do
    Map.delete(relay, :supported_nips)
  end

  defp normalize_relay_info(relay), do: relay

  defp normalize_supported_nips(supported_nips) when is_list(supported_nips) do
    supported_nips
    |> Enum.filter(&(is_integer(&1) and &1 >= 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp merge_relay_identity(%{relay: relay}) when is_map(relay) do
    current = Application.get_env(:nostr_relay, :relay_identity, [])

    overrides =
      relay
      |> Map.take(@relay_identity_keys)
      |> Enum.to_list()

    Application.put_env(:nostr_relay, :relay_identity, Keyword.merge(current, overrides))
  end

  defp merge_relay_identity(_toml), do: :ok

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

  defp merge_nip29(%{nip29: nip29}) when is_map(nip29) do
    current = Application.get_env(:nostr_relay, :nip29, [])

    overrides =
      nip29
      |> Map.take(@nip29_keys)
      |> normalize_nip29_maps()
      |> Enum.to_list()

    Application.put_env(:nostr_relay, :nip29, Keyword.merge(current, overrides))
  end

  defp merge_nip29(_toml), do: :ok

  defp normalize_nip29_maps(nip29) do
    nip29
    |> normalize_optional_checks()
    |> normalize_joins()
    |> normalize_roles()
  end

  defp normalize_optional_checks(%{optional_checks: value} = nip29) when is_map(value) do
    Map.put(nip29, :optional_checks, value)
  end

  defp normalize_optional_checks(nip29), do: nip29

  defp normalize_joins(%{joins: value} = nip29) when is_map(value) do
    Map.put(nip29, :joins, value)
  end

  defp normalize_joins(nip29), do: nip29

  defp normalize_roles(%{roles: value} = nip29) when is_map(value) do
    roles =
      value
      |> Enum.map(fn {key, capabilities} ->
        {to_string(key), normalize_capabilities(capabilities)}
      end)
      |> Map.new()

    Map.put(nip29, :roles, roles)
  end

  defp normalize_roles(nip29), do: nip29

  defp normalize_capabilities(capabilities) when is_list(capabilities) do
    Enum.map(capabilities, &normalize_capability/1)
  end

  defp normalize_capabilities(_capabilities), do: []

  defp normalize_capability(capability) when is_atom(capability), do: capability

  defp normalize_capability(capability) when is_binary(capability) do
    capability
    |> String.trim()
    |> normalize_capability_name()
  end

  defp normalize_capability(_capability), do: :unknown

  defp normalize_capability_name(capability_name) do
    Map.get(@capability_names, capability_name, :unknown)
  end

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
