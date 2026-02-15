defmodule Nostr.Relay.Pipeline.Stages.ProtocolValidator do
  @moduledoc """
  Parse and validate raw websocket JSON payload into a protocol message tuple.

  This stage is responsible for turning raw frames into `Nostr.Message` forms and
  mapping parse failures into `:invalid_message_format` so the engine can emit the
  standard notice.
  """

  alias Nostr.Message
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage

  @behaviour Stage

  @impl Stage
  @spec call(Context.t(), keyword()) :: Stage.t()
  def call(%Context{} = context, _options) do
    context
    |> parse_message()
  end

  defp parse_message(%Context{raw_frame: raw_frame} = context) when is_binary(raw_frame) do
    raw_frame
    |> safe_parse()
    |> case do
      {:error, reason} -> {:error, reason, Context.set_error(context, reason)}
      parsed_message -> {:ok, Context.with_parsed_message(context, parsed_message)}
    end
  end

  defp parse_message(%Context{} = context) do
    reason = :invalid_message_format
    {:error, reason, Context.set_error(context, reason)}
  end

  defp safe_parse(raw_frame) when is_binary(raw_frame) do
    try do
      Message.parse(raw_frame)
    rescue
      _ -> {:error, :invalid_message_format}
    end
    |> case do
      :error -> {:error, :invalid_message_format}
      parsed_message -> parsed_message
    end
  end
end
