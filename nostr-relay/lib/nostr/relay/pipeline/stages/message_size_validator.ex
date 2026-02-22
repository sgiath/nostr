defmodule Nostr.Relay.Pipeline.Stages.MessageSizeValidator do
  @moduledoc """
  Enforce inbound message size limits before protocol parsing.

  NIP-11 exposes `limitation.max_message_length` as the maximum JSON payload
  size accepted from clients. This stage rejects oversized websocket text
  payloads early so downstream protocol parsing and validation never run on
  frames above the configured limit.
  """

  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage

  @behaviour Stage

  @default_max_message_length 8_000_000

  @impl Stage
  @spec call(Context.t(), keyword()) :: Stage.t()
  def call(%Context{raw_frame: raw_frame} = context, _options) when is_binary(raw_frame) do
    if byte_size(raw_frame) <= max_message_length() do
      {:ok, context}
    else
      {:error, :message_too_large, Context.set_error(context, :message_too_large)}
    end
  end

  def call(%Context{} = context, _options) do
    {:error, :invalid_message_format, Context.set_error(context, :invalid_message_format)}
  end

  defp max_message_length do
    case limitation_max_message_length() do
      value when is_integer(value) and value > 0 -> value
      _invalid -> @default_max_message_length
    end
  end

  defp limitation_max_message_length do
    :nostr_relay
    |> Application.get_env(:relay_info, [])
    |> Keyword.get(:limitation, %{})
    |> Map.get(:max_message_length)
  end
end
