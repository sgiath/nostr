defmodule Nostr.Client.SessionKey do
  @moduledoc false

  @type t() :: {relay_url :: binary(), {:pubkey, pubkey :: binary()}}

  @spec build(binary(), binary()) :: {:ok, t()} | {:error, term()}
  def build(relay_url, pubkey) when is_binary(relay_url) and is_binary(pubkey) do
    with {:ok, normalized_relay_url} <- normalize_relay_url(relay_url),
         {:ok, normalized_pubkey} <- normalize_pubkey(pubkey) do
      {:ok, {normalized_relay_url, {:pubkey, normalized_pubkey}}}
    end
  end

  @spec normalize_relay_url(binary()) :: {:ok, binary()} | {:error, :invalid_relay_url}
  def normalize_relay_url(relay_url) when is_binary(relay_url) do
    uri = URI.parse(relay_url)

    with {:ok, scheme} <- normalize_scheme(uri),
         {:ok, host} <- normalize_host(uri),
         {:ok, port} <- normalize_port(uri, scheme) do
      path = normalize_path(uri.path)
      query = normalize_query(uri.query)
      authority = authority(host, port, scheme)

      {:ok, "#{scheme}://#{authority}#{path}#{query}"}
    end
  end

  @spec normalize_pubkey(binary()) :: {:ok, binary()} | {:error, :invalid_pubkey}
  def normalize_pubkey(pubkey) when is_binary(pubkey) do
    normalized_pubkey = String.downcase(pubkey)

    if String.match?(normalized_pubkey, ~r/\A[0-9a-f]{64}\z/) do
      {:ok, normalized_pubkey}
    else
      {:error, :invalid_pubkey}
    end
  end

  defp normalize_scheme(%URI{scheme: "ws"}), do: {:ok, "ws"}
  defp normalize_scheme(%URI{scheme: "wss"}), do: {:ok, "wss"}
  defp normalize_scheme(_uri), do: {:error, :invalid_relay_url}

  defp normalize_host(%URI{host: host}) when is_binary(host) and byte_size(host) > 0 do
    {:ok, String.downcase(host)}
  end

  defp normalize_host(_uri), do: {:error, :invalid_relay_url}

  defp normalize_port(%URI{port: port}, _scheme) when is_integer(port), do: {:ok, port}
  defp normalize_port(_uri, "ws"), do: {:ok, 80}
  defp normalize_port(_uri, "wss"), do: {:ok, 443}

  defp normalize_path(nil), do: "/"
  defp normalize_path(""), do: "/"
  defp normalize_path(<<"/", _::binary>> = path), do: path
  defp normalize_path(path), do: "/" <> path

  defp normalize_query(nil), do: ""
  defp normalize_query(""), do: ""
  defp normalize_query(query), do: "?" <> query

  defp authority(host, 80, "ws"), do: host
  defp authority(host, 443, "wss"), do: host
  defp authority(host, port, _scheme), do: "#{host}:#{port}"
end
