defmodule Nostr.Client.RelayInfo do
  @moduledoc """
  NIP-11 relay information document fetch and parsing.
  """

  alias Nostr.Client.SessionKey

  @known_json_fields [
    "name",
    "description",
    "banner",
    "icon",
    "pubkey",
    "self",
    "contact",
    "supported_nips",
    "software",
    "version",
    "privacy_policy",
    "terms_of_service",
    "limitation",
    "retention",
    "relay_countries",
    "language_tags",
    "tags",
    "posting_policy",
    "payments_url",
    "fees"
  ]

  defstruct name: nil,
            description: nil,
            banner: nil,
            icon: nil,
            pubkey: nil,
            self: nil,
            contact: nil,
            supported_nips: nil,
            software: nil,
            version: nil,
            privacy_policy: nil,
            terms_of_service: nil,
            limitation: nil,
            retention: nil,
            relay_countries: nil,
            language_tags: nil,
            tags: nil,
            posting_policy: nil,
            payments_url: nil,
            fees: nil,
            extra: %{},
            raw: %{}

  @type t() :: %__MODULE__{
          name: binary() | nil,
          description: binary() | nil,
          banner: binary() | nil,
          icon: binary() | nil,
          pubkey: binary() | nil,
          self: binary() | nil,
          contact: binary() | nil,
          supported_nips: [integer()] | nil,
          software: binary() | nil,
          version: binary() | nil,
          privacy_policy: binary() | nil,
          terms_of_service: binary() | nil,
          limitation: map() | nil,
          retention: [map()] | nil,
          relay_countries: [binary()] | nil,
          language_tags: [binary()] | nil,
          tags: [binary()] | nil,
          posting_policy: binary() | nil,
          payments_url: binary() | nil,
          fees: map() | nil,
          extra: map(),
          raw: map()
        }

  @type reason() ::
          :invalid_relay_url
          | :invalid_json
          | :invalid_document
          | {:http_status, pos_integer()}
          | {:request_failed, term()}

  @doc """
  Fetches and parses NIP-11 relay information for a relay URL.
  """
  @spec fetch(binary(), keyword()) :: {:ok, t()} | {:error, reason()}
  def fetch(relay_url, opts \\ []) when is_binary(relay_url) and is_list(opts) do
    with {:ok, raw} <- fetch_raw(relay_url, opts) do
      parse_document(raw)
    end
  end

  @doc """
  Fetches the raw NIP-11 document map.
  """
  @spec fetch_raw(binary(), keyword()) :: {:ok, map()} | {:error, reason()}
  def fetch_raw(relay_url, opts \\ []) when is_binary(relay_url) and is_list(opts) do
    with {:ok, url} <- relay_info_url(relay_url),
         req_opts <- build_req_opts(url, opts),
         result <- execute_request(req_opts) do
      handle_response(result)
    end
  end

  @spec execute_request(keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  defp execute_request(req_opts) do
    Req.get(req_opts)
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec parse_document(map()) :: {:ok, t()} | {:error, :invalid_document}
  defp parse_document(raw) when is_map(raw) do
    document = %__MODULE__{
      name: get_binary(raw, "name"),
      description: get_binary(raw, "description"),
      banner: get_binary(raw, "banner"),
      icon: get_binary(raw, "icon"),
      pubkey: get_binary(raw, "pubkey"),
      self: get_binary(raw, "self"),
      contact: get_binary(raw, "contact"),
      supported_nips: get_integer_list(raw, "supported_nips"),
      software: get_binary(raw, "software"),
      version: get_binary(raw, "version"),
      privacy_policy: get_binary(raw, "privacy_policy"),
      terms_of_service: get_binary(raw, "terms_of_service"),
      limitation: get_map(raw, "limitation"),
      retention: get_map_list(raw, "retention"),
      relay_countries: get_string_list(raw, "relay_countries"),
      language_tags: get_string_list(raw, "language_tags"),
      tags: get_string_list(raw, "tags"),
      posting_policy: get_binary(raw, "posting_policy"),
      payments_url: get_binary(raw, "payments_url"),
      fees: get_map(raw, "fees"),
      extra: Map.drop(raw, @known_json_fields),
      raw: raw
    }

    {:ok, document}
  end

  defp parse_document(_raw), do: {:error, :invalid_document}

  @spec relay_info_url(binary()) :: {:ok, URI.t()} | {:error, :invalid_relay_url}
  defp relay_info_url(relay_url) do
    with {:ok, normalized} <- SessionKey.normalize_relay_url(relay_url),
         %URI{} = uri <- URI.parse(normalized),
         scheme when scheme in ["ws", "wss"] <- uri.scheme do
      http_scheme = if scheme == "ws", do: "http", else: "https"
      {:ok, %URI{uri | scheme: http_scheme}}
    else
      _other -> {:error, :invalid_relay_url}
    end
  end

  @spec build_req_opts(URI.t(), keyword()) :: keyword()
  defp build_req_opts(url, opts) do
    default_headers = [{"accept", "application/nostr+json"}]

    opts
    |> Keyword.put_new(:headers, default_headers)
    |> Keyword.merge(
      url: URI.to_string(url),
      redirect: false,
      retry: false,
      connect_options: [timeout: 3_000],
      receive_timeout: 5_000
    )
    |> ensure_accept_header()
  end

  @spec ensure_accept_header(keyword()) :: keyword()
  defp ensure_accept_header(opts) do
    headers = Keyword.get(opts, :headers, [])

    has_accept? =
      Enum.any?(headers, fn
        {header, _value} when is_binary(header) -> String.downcase(header) == "accept"
        {header, _value} when is_atom(header) -> header == :accept
        _other -> false
      end)

    if has_accept? do
      opts
    else
      Keyword.update(opts, :headers, [{"accept", "application/nostr+json"}], fn existing ->
        [{"accept", "application/nostr+json"} | existing]
      end)
    end
  end

  @spec handle_response({:ok, Req.Response.t()} | {:error, term()}) ::
          {:ok, map()} | {:error, reason()}
  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) when is_map(body) do
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :invalid_document}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp handle_response({:ok, %Req.Response{status: 200}}), do: {:error, :invalid_document}

  defp handle_response({:ok, %Req.Response{status: status}}) when is_integer(status) do
    {:error, {:http_status, status}}
  end

  defp handle_response({:error, reason}), do: {:error, {:request_failed, reason}}

  @spec get_binary(map(), binary()) :: binary() | nil
  defp get_binary(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  @spec get_map(map(), binary()) :: map() | nil
  defp get_map(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _other -> nil
    end
  end

  @spec get_map_list(map(), binary()) :: [map()] | nil
  defp get_map_list(map, key) do
    case Map.get(map, key) do
      values when is_list(values) -> if(Enum.all?(values, &is_map/1), do: values, else: nil)
      _other -> nil
    end
  end

  @spec get_integer_list(map(), binary()) :: [integer()] | nil
  defp get_integer_list(map, key) do
    case Map.get(map, key) do
      values when is_list(values) -> if(Enum.all?(values, &is_integer/1), do: values, else: nil)
      _other -> nil
    end
  end

  @spec get_string_list(map(), binary()) :: [binary()] | nil
  defp get_string_list(map, key) do
    case Map.get(map, key) do
      values when is_list(values) -> if(Enum.all?(values, &is_binary/1), do: values, else: nil)
      _other -> nil
    end
  end
end
