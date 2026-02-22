defmodule Nostr.Auth.Plug do
  @moduledoc """
  Plug/Phoenix adapter helpers for NIP-98 validation.

  This module converts `Plug.Conn` data into `Nostr.NIP98` request context and
  delegates validation to `Nostr.Auth`.
  """

  alias Nostr.Auth
  alias Nostr.Event
  alias Plug.Conn

  @typedoc "Error values returned by this module."
  @type error() ::
          Auth.error()
          | :missing_authorization_header
          | :invalid_request_context

  @doc """
  Returns the first request `authorization` header.
  """
  @spec authorization_header(Conn.t()) ::
          {:ok, String.t()} | {:error, :missing_authorization_header}
  def authorization_header(%Conn{} = conn) do
    case Conn.get_req_header(conn, "authorization") do
      [header | _rest] when is_binary(header) and header != "" -> {:ok, header}
      _none -> {:error, :missing_authorization_header}
    end
  end

  @doc """
  Builds NIP-98 request context from a `Plug.Conn`.

  ## Options

  - `:url` - explicit URL override
  - `:body` - raw body bytes used for payload hash validation
  - `:payload_hash` - precomputed payload SHA256 hex
  """
  @spec request_context(Conn.t(), keyword()) :: Nostr.NIP98.request_context()
  def request_context(%Conn{} = conn, opts \\ []) do
    url = Keyword.get(opts, :url, request_url(conn))
    method = conn.method

    %{url: url, method: method}
    |> maybe_put_payload_hash(opts)
    |> maybe_put_body(opts)
  end

  @doc """
  Validates NIP-98 authorization from a `Plug.Conn`.

  ## Options

  - `:request_context` - explicit `Nostr.NIP98` request context override
  - `:url`, `:body`, `:payload_hash` - context builders passed to `request_context/2`
  - `:nip98` - options forwarded to `Nostr.NIP98.validate_request/3`
  - `:replay` - replay adapter tuple (`{module, opts}`)
  """
  @spec validate_conn(Conn.t(), keyword()) :: {:ok, Event.t()} | {:error, error()}
  def validate_conn(%Conn{} = conn, opts \\ []) do
    context = Keyword.get(opts, :request_context, request_context(conn, opts))

    with {:ok, header} <- authorization_header(conn) do
      Auth.validate_authorization_header(header, context, passthrough_opts(opts))
    end
  end

  @doc """
  Builds the request URL from conn components.

  Includes the query string when present.
  """
  @spec request_url(Conn.t()) :: String.t()
  def request_url(%Conn{} = conn) do
    base = "#{conn.scheme}://#{conn.host}#{port_segment(conn)}#{conn.request_path}"

    case conn.query_string do
      "" -> base
      query -> base <> "?" <> query
    end
  end

  # Private helpers

  defp passthrough_opts(opts) do
    opts
    |> Keyword.take([:nip98, :replay])
  end

  defp maybe_put_payload_hash(context, opts) do
    case Keyword.get(opts, :payload_hash) do
      payload_hash when is_binary(payload_hash) and payload_hash != "" ->
        Map.put(context, :payload_hash, payload_hash)

      _none ->
        context
    end
  end

  defp maybe_put_body(context, opts) do
    case Keyword.get(opts, :body) do
      body when is_binary(body) ->
        Map.put(context, :body, body)

      _none ->
        context
    end
  end

  defp port_segment(%Conn{scheme: :https, port: 443}), do: ""
  defp port_segment(%Conn{scheme: :http, port: 80}), do: ""
  defp port_segment(%Conn{port: port}) when is_integer(port), do: ":#{port}"
  defp port_segment(_conn), do: ""
end
