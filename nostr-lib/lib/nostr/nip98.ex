defmodule Nostr.NIP98 do
  @moduledoc """
  NIP-98: HTTP Auth helpers.

  This module validates the event-side semantics of NIP-98 HTTP authorization
  events (kind 27235).
  """
  @moduledoc tags: [:nip98], nip: 98

  alias Nostr.Event
  alias Nostr.Event.HttpAuth
  alias Nostr.Tag

  @kind 27_235

  @typedoc "Request data required to validate a NIP-98 event against an HTTP request."
  @type request_context() :: %{
          required(:url) => String.t(),
          required(:method) => String.t(),
          optional(:body) => binary() | nil,
          optional(:payload_hash) => String.t() | nil
        }

  @typedoc "How payload validation should be applied."
  @type payload_policy() :: :if_present | :require | :ignore

  @typedoc "Validation errors returned by `validate_request/3`."
  @type validation_error() ::
          :invalid_request_context
          | :invalid_kind
          | :missing_created_at
          | {:created_at_too_old, now_unix :: integer(), event_unix :: integer()}
          | {:created_at_too_new, now_unix :: integer(), event_unix :: integer()}
          | :missing_u_tag
          | :missing_method_tag
          | :duplicate_u_tag
          | :duplicate_method_tag
          | :duplicate_payload_tag
          | {:url_mismatch, expected :: String.t(), got :: String.t()}
          | {:method_mismatch, expected :: String.t(), got :: String.t()}
          | :missing_payload_tag
          | :invalid_payload_tag
          | :invalid_payload_hash
          | :missing_request_body
          | {:payload_mismatch, expected :: String.t(), got :: String.t()}
          | :non_empty_content

  @doc """
  Validates a NIP-98 HTTP auth event against request context.

  This function validates only event semantics. Authorization header decoding,
  replay protection, and pubkey authorization policy are intentionally out of
  scope and should be handled by application/adapter layers.

  ## Options

  - `:max_age_seconds` - max age of event from now (default: `60`)
  - `:max_future_seconds` - allowed future skew (default: `0`)
  - `:now` - current time as `DateTime.t()` or unix seconds
  - `:payload_policy` - one of `:if_present`, `:require`, `:ignore` (default: `:if_present`)
  - `:enforce_content_empty?` - enforce empty content (default: `false`)
  """
  @spec validate_request(Event.t() | HttpAuth.t(), request_context(), Keyword.t()) ::
          :ok | {:error, validation_error()}
  def validate_request(event_or_auth, request_context, opts \\ [])

  def validate_request(event_or_auth, %{url: url, method: method} = request_context, opts)
      when is_binary(url) and is_binary(method) do
    with {:ok, event} <- normalize_event(event_or_auth),
         :ok <- validate_kind(event),
         :ok <- maybe_validate_content(event, opts),
         {:ok, now_unix} <- resolve_now_unix(opts),
         :ok <- validate_created_at(event, now_unix, opts),
         {:ok, url_tag} <- required_single_tag(event.tags, :u, :missing_u_tag, :duplicate_u_tag),
         {:ok, method_tag} <-
           required_single_tag(event.tags, :method, :missing_method_tag, :duplicate_method_tag),
         {:ok, payload_tag} <- optional_single_tag(event.tags, :payload, :duplicate_payload_tag),
         :ok <- validate_url(url_tag, request_context),
         :ok <- validate_method(method_tag, request_context) do
      validate_payload(payload_tag, request_context, opts)
    end
  end

  def validate_request(_event_or_auth, _request_context, _opts) do
    {:error, :invalid_request_context}
  end

  @doc """
  Computes a SHA256 hash hex string for request payload bytes.
  """
  @spec payload_hash(binary()) :: String.t()
  def payload_hash(payload) when is_binary(payload) do
    :sha256
    |> :crypto.hash(payload)
    |> Base.encode16(case: :lower)
  end

  # Private helpers

  defp normalize_event(%HttpAuth{event: %Event{} = event}), do: {:ok, event}
  defp normalize_event(%Event{} = event), do: {:ok, event}
  defp normalize_event(_other), do: {:error, :invalid_request_context}

  defp validate_kind(%Event{kind: @kind}), do: :ok
  defp validate_kind(%Event{}), do: {:error, :invalid_kind}

  defp maybe_validate_content(%Event{content: ""}, _opts), do: :ok

  defp maybe_validate_content(%Event{}, opts) do
    if Keyword.get(opts, :enforce_content_empty?, false) do
      {:error, :non_empty_content}
    else
      :ok
    end
  end

  defp resolve_now_unix(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case now do
      %DateTime{} = datetime -> {:ok, DateTime.to_unix(datetime)}
      unix when is_integer(unix) -> {:ok, unix}
      _other -> {:ok, DateTime.to_unix(DateTime.utc_now())}
    end
  end

  defp validate_created_at(%Event{created_at: nil}, _now_unix, _opts),
    do: {:error, :missing_created_at}

  defp validate_created_at(%Event{created_at: %DateTime{} = created_at}, now_unix, opts) do
    event_unix = DateTime.to_unix(created_at)
    max_age = Keyword.get(opts, :max_age_seconds, 60)
    max_future = Keyword.get(opts, :max_future_seconds, 0)

    cond do
      event_unix < now_unix - max_age ->
        {:error, {:created_at_too_old, now_unix, event_unix}}

      event_unix > now_unix + max_future ->
        {:error, {:created_at_too_new, now_unix, event_unix}}

      true ->
        :ok
    end
  end

  defp required_single_tag(tags, type, missing_reason, duplicate_reason) do
    case tags
         |> Enum.filter(&tag_matches_type?(&1, type))
         |> Enum.map(& &1.data) do
      [] -> {:error, missing_reason}
      [value] -> {:ok, value}
      [_first | _rest] -> {:error, duplicate_reason}
    end
  end

  defp optional_single_tag(tags, type, duplicate_reason) do
    case tags
         |> Enum.filter(&tag_matches_type?(&1, type))
         |> Enum.map(& &1.data) do
      [] -> {:ok, nil}
      [value] -> {:ok, String.downcase(value)}
      [_first | _rest] -> {:error, duplicate_reason}
    end
  end

  defp tag_matches_type?(%Tag{type: type, data: data}, expected_type)
       when type == expected_type and is_binary(data),
       do: true

  defp tag_matches_type?(_tag, _expected_type), do: false

  defp validate_url(url_tag, %{url: url}) when url_tag == url, do: :ok
  defp validate_url(url_tag, %{url: url}), do: {:error, {:url_mismatch, url, url_tag}}

  defp validate_method(method_tag, %{method: method}) do
    if String.upcase(method_tag) == String.upcase(method) do
      :ok
    else
      {:error, {:method_mismatch, method, method_tag}}
    end
  end

  defp validate_payload(payload_tag, request_context, opts) do
    case Keyword.get(opts, :payload_policy, :if_present) do
      :ignore ->
        :ok

      :require ->
        validate_payload_required(payload_tag, request_context)

      :if_present ->
        validate_payload_if_present(payload_tag, request_context)

      _other ->
        validate_payload_if_present(payload_tag, request_context)
    end
  end

  defp validate_payload_required(nil, _request_context), do: {:error, :missing_payload_tag}

  defp validate_payload_required(payload_tag, request_context) do
    compare_payload_hash(payload_tag, request_context)
  end

  defp validate_payload_if_present(nil, _request_context), do: :ok

  defp validate_payload_if_present(payload_tag, request_context) do
    compare_payload_hash(payload_tag, request_context)
  end

  defp compare_payload_hash(payload_tag, request_context) do
    with :ok <- validate_sha256_hex(payload_tag),
         {:ok, expected} <- expected_payload_hash(request_context) do
      if payload_tag == expected do
        :ok
      else
        {:error, {:payload_mismatch, expected, payload_tag}}
      end
    end
  end

  defp expected_payload_hash(%{payload_hash: hash}) when is_binary(hash) do
    hash = String.downcase(hash)

    case validate_sha256_hex(hash) do
      :ok -> {:ok, hash}
      {:error, _reason} -> {:error, :invalid_payload_hash}
    end
  end

  defp expected_payload_hash(%{body: body}) when is_binary(body), do: {:ok, payload_hash(body)}
  defp expected_payload_hash(_request_context), do: {:error, :missing_request_body}

  defp validate_sha256_hex(hash) when is_binary(hash) and byte_size(hash) == 64 do
    case Base.decode16(hash, case: :mixed) do
      {:ok, decoded} when byte_size(decoded) == 32 -> :ok
      _error -> {:error, :invalid_payload_tag}
    end
  end

  defp validate_sha256_hex(_hash), do: {:error, :invalid_payload_tag}
end
