defmodule Nostr.Relay.Pipeline.Stages.EventValidator do
  @moduledoc """
  Verify event ID hash and Schnorr signature for inbound EVENT messages.

  NIP-01 requires relays to check that the event `id` is the SHA-256 hash of
  the serialized event, and that `sig` is a valid Schnorr signature over that
  ID using the event's `pubkey`.  It also requires relays to respond with
  `["OK", <event-id>, false, "invalid: ..."]` for rejected events.

  This stage runs after `MessageValidator` so it only sees structurally valid
  `{:event, %Event{}}` tuples. For non-event messages the stage is a no-op.

  On validation failure the stage queues an `OK` error frame in the context and
  halts the pipeline with `:invalid_event_id`, `:invalid_event_created_at`,
  `:invalid_event_sig`, or `:invalid_event_tags`.  The
  engine will push the queued frame instead of generating a generic NOTICE.
  """

  alias Nostr.Event
  alias Nostr.Message
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage

  @behaviour Stage

  @impl Stage
  @spec call(Context.t(), keyword()) :: Stage.t()
  def call(%Context{parsed_message: {:event, %Event{} = event}} = context, _options) do
    validate_event(event, context)
  end

  def call(%Context{parsed_message: {:event, _sub_id, %Event{} = event}} = context, _options) do
    validate_event(event, context)
  end

  def call(%Context{} = context, _options), do: {:ok, context}

  defp validate_event(%Event{created_at: %DateTime{}} = event, %Context{} = context) do
    validate_signed_event(event, context)
  end

  defp validate_event(%Event{} = event, %Context{} = context) do
    reject(event.id, :invalid_event_created_at, "invalid: invalid created_at", context)
  end

  defp validate_signed_event(%Event{} = event, %Context{} = context) do
    cond do
      not event_id_matches?(event, context) ->
        reject(event.id, :invalid_event_id, "invalid: event id does not match", context)

      not tags_valid?(context) ->
        reject(event.id, :invalid_event_tags, "invalid: malformed tags", context)

      not signature_valid?(event) ->
        reject(
          event.id,
          :invalid_event_sig,
          "invalid: event signature verification failed",
          context
        )

      true ->
        {:ok, context}
    end
  end

  defp event_id_matches?(%Event{} = event, %Context{} = context) do
    case raw_event_id(context) do
      {:ok, raw_id} -> raw_id == event.id
      :error -> Event.compute_id(event) == event.id
    end
  end

  defp raw_event_id(%Context{} = context) do
    with {:ok, raw_event} <- parse_raw_event(context),
         {:ok, created_at} <- parse_raw_created_at(raw_event["created_at"]),
         %{} = raw_event,
         tags when is_list(tags) <- Map.get(raw_event, "tags", []) do
      {:ok,
       Event.compute_id(%Event{
         pubkey: Map.get(raw_event, "pubkey"),
         kind: Map.get(raw_event, "kind"),
         tags: tags,
         created_at: created_at,
         content: Map.get(raw_event, "content")
       })}
    else
      _ -> :error
    end
  end

  defp parse_raw_event(%Context{raw_frame: raw_frame}) when is_binary(raw_frame) do
    case JSON.decode(raw_frame) do
      {:ok, ["EVENT", %{} = event]} -> {:ok, event}
      _ -> :error
    end
  end

  defp parse_raw_event(_context), do: :error

  defp parse_raw_created_at(created_at) when is_integer(created_at) do
    case DateTime.from_unix(created_at) do
      {:ok, dt} -> {:ok, dt}
      {:error, _} -> :error
    end
  end

  defp parse_raw_created_at(_), do: :error

  defp signature_valid?(%Event{id: event_id, sig: sig, pubkey: pubkey}) do
    with {:ok, sig_bytes} <- decode_hex(sig),
         {:ok, id_bytes} <- decode_hex(event_id),
         {:ok, pubkey_bytes} <- decode_hex(pubkey) do
      Secp256k1.schnorr_valid?(sig_bytes, id_bytes, pubkey_bytes)
    else
      _ -> false
    end
  end

  defp signature_valid?(_event), do: false

  defp decode_hex(value) when is_binary(value), do: Base.decode16(value, case: :lower)
  defp decode_hex(_), do: :error

  defp tags_valid?(%Context{} = context) do
    case parse_raw_event(context) do
      {:ok, %{} = event} ->
        case Map.get(event, "tags") do
          tags when is_list(tags) -> Enum.all?(tags, &valid_tag?/1)
          _ -> false
        end

      _ ->
        true
    end
  end

  defp valid_tag?(tag) when is_list(tag), do: tag != [] and Enum.all?(tag, &is_binary/1)
  defp valid_tag?(_), do: false

  defp reject(event_id, reason, message, %Context{} = context) do
    frame = ok_frame(event_id, false, message)

    context =
      context
      |> Context.add_frame(frame)
      |> Context.set_error(reason)

    {:error, reason, context}
  end

  defp ok_frame(event_id, success?, message) do
    serialized =
      event_id
      |> Message.ok(success?, message)
      |> Message.serialize()

    {:text, serialized}
  end
end
