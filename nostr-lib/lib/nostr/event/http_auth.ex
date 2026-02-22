defmodule Nostr.Event.HttpAuth do
  @moduledoc """
  HTTP authentication events (kind 27235).

  Implements NIP-98: https://github.com/nostr-protocol/nips/blob/master/98.md

  Required tags:
  - `u` - absolute request URL
  - `method` - HTTP method

  Optional tags:
  - `payload` - request payload SHA256 hash (hex)
  """
  @moduledoc tags: [:event, :nip98], nip: 98

  alias Nostr.Event
  alias Nostr.Tag

  @kind 27_235

  defstruct [:event, :url, :method, :payload]

  @type t() :: %__MODULE__{
          event: Event.t(),
          url: String.t() | nil,
          method: String.t() | nil,
          payload: String.t() | nil
        }

  @doc """
  Parses a kind 27235 event into an `HttpAuth` struct.
  """
  @spec parse(Event.t()) :: t() | {:error, String.t(), Event.t()}
  def parse(%Event{kind: @kind} = event) do
    with {:ok, url} <- required_single_tag(event.tags, :u, :missing_u_tag, :duplicate_u_tag),
         {:ok, method} <-
           required_single_tag(event.tags, :method, :missing_method_tag, :duplicate_method_tag),
         {:ok, payload} <- optional_single_tag(event.tags, :payload, :duplicate_payload_tag),
         :ok <- validate_payload_tag(payload) do
      %__MODULE__{event: event, url: url, method: method, payload: payload}
    else
      {:error, reason} -> {:error, error_message(reason), event}
    end
  end

  def parse(%Event{} = event) do
    {:error, "Event is not an HTTP auth event (expected kind 27235)", event}
  end

  @doc """
  Creates a new HTTP auth event.

  ## Options

  - `:payload` - raw request body to hash into a `payload` tag
  - `:payload_hash` - precomputed SHA256 hex for the `payload` tag
  - `:pubkey` - event pubkey (optional)
  - `:created_at` - event timestamp (optional)
  - `:tags` - additional tags to append (optional)
  - `:content` - event content (defaults to empty string)
  """
  @spec create(String.t(), String.t(), Keyword.t()) :: t()
  def create(url, method, opts \\ []) when is_binary(url) and is_binary(method) do
    payload_hash =
      case {Keyword.get(opts, :payload_hash), Keyword.get(opts, :payload)} do
        {hash, _payload} when is_binary(hash) -> String.downcase(hash)
        {nil, payload} when is_binary(payload) -> payload_hash(payload)
        _none -> nil
      end

    required_tags =
      [Tag.create(:u, url), Tag.create(:method, method)] ++ maybe_payload_tag(payload_hash)

    event_opts =
      opts
      |> Keyword.take([:pubkey, :created_at, :content, :tags])
      |> Keyword.put_new(:content, "")
      |> Keyword.update(:tags, required_tags, &(required_tags ++ &1))

    event = Event.create(@kind, event_opts)

    %__MODULE__{event: event, url: url, method: method, payload: payload_hash}
  end

  # Private helpers

  defp required_single_tag(tags, type, missing_reason, duplicate_reason) do
    case tags
         |> Enum.filter(&(&1.type == type and is_binary(&1.data)))
         |> Enum.map(& &1.data) do
      [] -> {:error, missing_reason}
      [value] -> {:ok, value}
      [_first | _rest] -> {:error, duplicate_reason}
    end
  end

  defp optional_single_tag(tags, type, duplicate_reason) do
    case tags
         |> Enum.filter(&(&1.type == type and is_binary(&1.data)))
         |> Enum.map(& &1.data) do
      [] -> {:ok, nil}
      [value] -> {:ok, String.downcase(value)}
      [_first | _rest] -> {:error, duplicate_reason}
    end
  end

  defp validate_payload_tag(nil), do: :ok

  defp validate_payload_tag(payload) when is_binary(payload) do
    if valid_sha256_hex?(payload), do: :ok, else: {:error, :invalid_payload_tag}
  end

  defp maybe_payload_tag(nil), do: []
  defp maybe_payload_tag(payload_hash), do: [Tag.create(:payload, payload_hash)]

  defp payload_hash(payload) when is_binary(payload) do
    :sha256
    |> :crypto.hash(payload)
    |> Base.encode16(case: :lower)
  end

  defp valid_sha256_hex?(hash) when is_binary(hash) and byte_size(hash) == 64 do
    case Base.decode16(hash, case: :mixed) do
      {:ok, decoded} -> byte_size(decoded) == 32
      :error -> false
    end
  end

  defp valid_sha256_hex?(_hash), do: false

  defp error_message(:missing_u_tag), do: "HTTP auth event must have exactly one u tag"
  defp error_message(:missing_method_tag), do: "HTTP auth event must have exactly one method tag"
  defp error_message(:duplicate_u_tag), do: "HTTP auth event must not contain multiple u tags"

  defp error_message(:duplicate_method_tag),
    do: "HTTP auth event must not contain multiple method tags"

  defp error_message(:duplicate_payload_tag),
    do: "HTTP auth event must not contain multiple payload tags"

  defp error_message(:invalid_payload_tag),
    do: "HTTP auth payload tag must be a 64-char SHA256 hex"
end
