defmodule Nostr.Relay.Pipeline.Stages.StorePolicy do
  @moduledoc """
  Store policy and post-processing hook.

  Enforces write-side storage policy after protocol-level validation.

   NIP-09 restriction:

  Deletion events (`kind: 5`) may only target events published by the same
  pubkey that authored the deletion.

  NIP-59 restriction:
  - Gift-wrap events (`kind: 1059`) must include at least one valid recipient
  tag (`p`) before they can be stored.

  All `p` tags on a gift-wrap must be valid 32-byte hex pubkeys; malformed
  recipient tags are rejected to avoid leaking opaque metadata.
  """

  import Ecto.Query

  alias Nostr.Event
  alias Nostr.Message
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage
  alias Nostr.Relay.Repo
  alias Nostr.Relay.Store.Event, as: EventRecord
  alias Nostr.Tag

  @behaviour Stage

  @impl Stage
  @spec call(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, atom(), Context.t()}
  def call(%Context{parsed_message: {:event, %Event{kind: 5} = event}} = context, _options) do
    validate_delete_event_policy(event, context)
  end

  def call(%Context{parsed_message: {:event, %Event{kind: 10_59} = event}} = context, _options) do
    validate_gift_wrap_policy(event, context)
  end

  def call(
        %Context{parsed_message: {:event, _sub_id, %Event{kind: 5} = event}} = context,
        _options
      ) do
    validate_delete_event_policy(event, context)
  end

  def call(
        %Context{parsed_message: {:event, _sub_id, %Event{kind: 10_59} = event}} = context,
        _options
      ) do
    validate_gift_wrap_policy(event, context)
  end

  def call(%Context{} = context, _options), do: {:ok, context}

  defp validate_delete_event_policy(
         %Event{pubkey: signer_pubkey, id: event_id, tags: tags},
         context
       )
       when is_binary(signer_pubkey) and is_list(tags) do
    if unauthorized_deletion_target?(tags, signer_pubkey) do
      context =
        context
        |> Context.add_frame(
          ok_frame(event_id, false, "rejected: deletion can only target events by same pubkey")
        )
        |> Context.set_error(:nip09_restricted)

      {:error, :nip09_restricted, context}
    else
      {:ok, context}
    end
  end

  defp validate_delete_event_policy(_event, context), do: {:ok, context}

  defp validate_gift_wrap_policy(%Event{tags: tags, id: event_id}, context)
       when is_list(tags) do
    if has_valid_recipient_tags?(tags) do
      {:ok, context}
    else
      context =
        context
        |> Context.add_frame(
          ok_frame(
            event_id,
            false,
            "rejected: gift-wrap requires at least one valid recipient p tag"
          )
        )
        |> Context.set_error(:gift_wrap_invalid_recipient)

      {:error, :gift_wrap_invalid_recipient, context}
    end
  end

  defp validate_gift_wrap_policy(_event, context), do: {:ok, context}

  defp has_valid_recipient_tags?(tags) when is_list(tags) do
    recipient_tags = Enum.filter(tags, &(&1.type == :p))

    Enum.any?(recipient_tags, &valid_recipient_tag?/1) and
      Enum.all?(recipient_tags, &valid_recipient_tag?/1)
  end

  defp valid_recipient_tag?(%Tag{type: :p, data: data}), do: valid_pubkey?(data)
  defp valid_recipient_tag?(_tag), do: false

  defp valid_pubkey?(data) when is_binary(data) do
    case Base.decode16(data, case: :lower) do
      {:ok, pubkey} when byte_size(pubkey) == 32 -> true
      _ -> false
    end
  end

  defp valid_pubkey?(_), do: false

  defp unauthorized_deletion_target?(tags, signer_pubkey) when is_list(tags) do
    unauthorized_event_id_target?(tags, signer_pubkey) or
      unauthorized_address_target?(tags, signer_pubkey)
  end

  defp unauthorized_deletion_target?(_tags, _signer_pubkey), do: false

  defp unauthorized_event_id_target?(tags, signer_pubkey) when is_list(tags) do
    tags
    |> Enum.reduce([], fn
      %Tag{type: :e, data: data}, acc when is_binary(data) and byte_size(data) == 64 ->
        [data | acc]

      _tag, acc ->
        acc
    end)
    |> Enum.uniq()
    |> target_event_pubkeys_not_owned_by(signer_pubkey)
  end

  defp unauthorized_event_id_target?(_tags, _signer_pubkey), do: false

  defp target_event_pubkeys_not_owned_by(event_ids, _signer_pubkey) when event_ids == [] do
    false
  end

  defp target_event_pubkeys_not_owned_by(event_ids, signer_pubkey) when is_list(event_ids) do
    from(record in EventRecord, where: record.event_id in ^event_ids, select: record.pubkey)
    |> Repo.all()
    |> Enum.any?(&(&1 != signer_pubkey))
  end

  defp target_event_pubkeys_not_owned_by(_event_ids, _signer_pubkey), do: false

  defp unauthorized_address_target?(tags, signer_pubkey) when is_list(tags) do
    Enum.any?(tags, fn
      %Tag{type: :a, data: data} ->
        case parse_address_tag(data) do
          {:ok, {_kind, target_pubkey, _d_tag}} when is_binary(target_pubkey) ->
            target_pubkey != signer_pubkey

          _ ->
            false
        end

      _ ->
        false
    end)
  end

  defp unauthorized_address_target?(_tags, _signer_pubkey), do: false

  defp parse_address_tag(value) when is_binary(value) do
    case String.split(value, ":", parts: 3) do
      [kind_value, pubkey, d_tag] ->
        case parse_address_kind(kind_value) do
          kind when is_integer(kind) and kind >= 0 ->
            {:ok, {kind, pubkey, d_tag}}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp parse_address_tag(_value), do: :error

  defp parse_address_kind(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {kind, ""} when kind >= 0 -> kind
      _ -> :error
    end
  end

  defp parse_address_kind(_value), do: :error

  defp ok_frame(event_id, success?, message) do
    serialized =
      event_id
      |> Message.ok(success?, message)
      |> Message.serialize()

    {:text, serialized}
  end
end
