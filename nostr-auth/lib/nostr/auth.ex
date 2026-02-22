defmodule Nostr.Auth do
  @moduledoc """
  NIP-98 authorization helpers for HTTP adapters.

  This module intentionally focuses on event-side validation only:

  - parse and verify Nostr events from `Authorization` headers;
  - validate NIP-98 semantics against request context via `Nostr.NIP98`;
  - expose a replay-check hook for adapter/application integrations.

  It does not implement policy decisions (allow/deny pubkeys) and does not
  provide storage; callers should enforce those concerns externally.
  """

  alias Nostr.Event
  alias Nostr.NIP98

  @typedoc "`Authorization` header value."
  @type authorization_header() :: String.t()

  @typedoc "Error values returned by this module."
  @type error() ::
          :missing_authorization_header
          | :invalid_authorization_header
          | :invalid_authorization_scheme
          | :invalid_authorization_token
          | :invalid_authorization_json
          | :invalid_nostr_event
          | :invalid_request_context
          | {:nip98, NIP98.validation_error()}
          | {:replay, term()}

  @typedoc "Header collection accepted by `extract_authorization_header/1`."
  @type headers() :: [{String.t(), String.t()}] | %{optional(String.t()) => String.t()}

  @doc """
  Extracts the `authorization` header value from request headers.

  Accepts map-style headers or list-style headers (`[{name, value}]`).
  """
  @spec extract_authorization_header(headers()) ::
          {:ok, authorization_header()} | {:error, :missing_authorization_header}
  def extract_authorization_header(headers) when is_map(headers) do
    case Map.get(headers, "authorization") || Map.get(headers, "Authorization") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_authorization_header}
    end
  end

  def extract_authorization_header(headers) when is_list(headers) do
    case Enum.find(headers, fn
           {name, value} when is_binary(name) and is_binary(value) ->
             String.downcase(name) == "authorization" and value != ""

           _other ->
             false
         end) do
      {_, value} -> {:ok, value}
      nil -> {:error, :missing_authorization_header}
    end
  end

  @doc """
  Decodes a NIP-98 `Authorization` header value into a JSON map.

  Expected format:

      "Nostr <base64-event-json>"
  """
  @spec decode_authorization_header(authorization_header()) ::
          {:ok, map()}
          | {:error,
             :invalid_authorization_header
             | :invalid_authorization_scheme
             | :invalid_authorization_token
             | :invalid_authorization_json}
  def decode_authorization_header(header) when is_binary(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] when scheme == "Nostr" and token != "" ->
        decode_authorization_token(token)

      [scheme, _token] when is_binary(scheme) ->
        {:error, :invalid_authorization_scheme}

      _other ->
        {:error, :invalid_authorization_header}
    end
  end

  @doc """
  Decodes and parses a Nostr event from a NIP-98 `Authorization` header.
  """
  @spec parse_authorization_header(authorization_header()) ::
          {:ok, Event.t()} | {:error, error()}
  def parse_authorization_header(header) when is_binary(header) do
    with {:ok, event_json} <- decode_authorization_header(header),
         %Event{} = event <- Event.parse(event_json) do
      {:ok, event}
    else
      nil -> {:error, :invalid_nostr_event}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parses and validates a NIP-98 `Authorization` header against request context.

  ## Options

  - `:nip98` - options forwarded to `Nostr.NIP98.validate_request/3`
  - `:replay` - `{module, opts}` where module implements `Nostr.Auth.ReplayCache`
  """
  @spec validate_authorization_header(authorization_header(), NIP98.request_context(), keyword()) ::
          {:ok, Event.t()} | {:error, error()}
  def validate_authorization_header(header, request_context, opts \\ []) when is_binary(header) do
    with {:ok, event} <- parse_authorization_header(header) do
      validate_event(event, request_context, opts)
    end
  end

  @doc """
  Validates a parsed event against NIP-98 request context.

  Returns the original event on success.
  """
  @spec validate_event(Event.t(), NIP98.request_context(), keyword()) ::
          {:ok, Event.t()} | {:error, error()}
  def validate_event(%Event{} = event, request_context, opts \\ []) do
    nip98_opts = Keyword.get(opts, :nip98, [])

    with :ok <- validate_request_context(request_context),
         :ok <- normalize_nip98_result(NIP98.validate_request(event, request_context, nip98_opts)),
         :ok <- maybe_check_replay(event, opts) do
      {:ok, event}
    end
  end

  # Private helpers

  defp decode_authorization_token(token) when is_binary(token) do
    with {:ok, json} <- Base.decode64(token),
         {:ok, decoded} <- JSON.decode(json),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      :error -> {:error, :invalid_authorization_token}
      {:error, _reason} -> {:error, :invalid_authorization_json}
      false -> {:error, :invalid_authorization_json}
    end
  end

  defp validate_request_context(%{url: url, method: method})
       when is_binary(url) and url != "" and is_binary(method) and method != "",
       do: :ok

  defp validate_request_context(_request_context), do: {:error, :invalid_request_context}

  defp normalize_nip98_result(:ok), do: :ok
  defp normalize_nip98_result({:error, reason}), do: {:error, {:nip98, reason}}

  defp maybe_check_replay(%Event{} = event, opts) do
    case Keyword.get(opts, :replay) do
      nil ->
        :ok

      {module, replay_opts} when is_atom(module) and is_list(replay_opts) ->
        case module.check_and_store(event, replay_opts) do
          :ok -> :ok
          {:error, reason} -> {:error, {:replay, reason}}
        end

      _other ->
        {:error, {:replay, :invalid_replay_adapter}}
    end
  end
end
