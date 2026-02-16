defmodule Nostr.Relay.Pipeline.Stages.ProtocolValidator do
  @moduledoc """
  Parse and validate raw websocket JSON payload into a protocol message tuple.

  This stage is responsible for turning raw frames into `Nostr.Message` forms and
  mapping parse failures into `:invalid_message_format` so the engine can emit the
  standard notice.

  When `Nostr.Message.parse/1` rejects an EVENT (e.g. invalid signature or ID hash),
  this stage falls back to unverified event parsing so that downstream stages can
  produce a NIP-01 compliant `OK` rejection response with the claimed event ID.
  """

  alias Nostr.Event
  alias Nostr.Message
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage

  @behaviour Stage

  @impl Stage
  @spec call(Context.t(), keyword()) :: Stage.t()
  def call(%Context{} = context, _options) do
    parse_message(context)
  end

  defp parse_message(%Context{raw_frame: raw_frame} = context) when is_binary(raw_frame) do
    safe_parse(raw_frame)
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
    case detect_scientific_created_at(raw_frame) do
      {:scientific_created_at, event} ->
        {:event, Map.put(event, :created_at, nil)}

      {:no_float_created_at, _} ->
        parse_message_or_fallback(raw_frame)
    end
  end

  defp parse_message_or_fallback(raw_frame) when is_binary(raw_frame) do
    case Message.parse_with_reason(raw_frame) do
      {:ok, parsed_message} ->
        parsed_message

      {:error, reason} when reason in [:unsupported_json_escape, :unsupported_json_literals] ->
        {:error, reason}

      {:error, _reason} ->
        try_unverified_event(raw_frame)
    end
  end

  defp detect_scientific_created_at(raw_frame) when is_binary(raw_frame) do
    case JSON.decode(raw_frame) do
      {:ok, ["EVENT", %{} = event]} ->
        if is_float(event["created_at"]) do
          {:scientific_created_at, Event.parse_unverified(event)}
        else
          {:no_float_created_at, nil}
        end

      _ ->
        {:no_float_created_at, nil}
    end
  end

  # When Message.parse rejects an EVENT (invalid sig/id), re-parse the event
  # struct without validation so the pipeline can produce an OK error response.
  defp try_unverified_event(raw_frame) do
    case JSON.decode(raw_frame) do
      {:ok, ["EVENT", event]} when is_map(event) ->
        {:event, Event.parse_unverified(event)}

      _ ->
        {:error, :invalid_message_format}
    end
  rescue
    _ -> {:error, :invalid_message_format}
  end
end
