defmodule Nostr.Relay.Pipeline.Stages.RelayPolicyValidator do
  @moduledoc """
  Relay policy gate for protocol constraints.

  Current checks:

  - `min_pow_difficulty` — when greater than zero, rejects EVENT messages that
    do not satisfy NIP-13 PoW and nonce difficulty commitment requirements.
  - `min_prefix_length` — rejects REQ/COUNT filters where `ids` or `authors`
    contain prefix values shorter than the configured minimum. Full 64-character
    hex IDs are always accepted regardless of this setting.
  """

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Message
  alias Nostr.NIP13
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage

  @behaviour Stage

  @impl Stage
  @spec call(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, atom(), Context.t()}
  def call(%Context{parsed_message: parsed_message} = context, _options) do
    case parsed_message do
      {:event, %Event{} = event} ->
        validate_event_policies(context, event)

      {:event, _sub_id, %Event{} = event} ->
        validate_event_policies(context, event)

      {:req, _sub_id, filters} when is_list(filters) ->
        validate_prefix_lengths(context, filters)

      {:count, _sub_id, filters} when is_list(filters) ->
        validate_prefix_lengths(context, filters)

      _other ->
        {:ok, context}
    end
  end

  defp validate_event_policies(context, event) do
    case validate_pow_policy(event) do
      :ok ->
        {:ok, context}

      {:error, {reason, message}} ->
        reject_event(context, event.id, reason, message)
    end
  end

  defp validate_pow_policy(event) do
    min_pow_difficulty = min_pow_difficulty()

    if min_pow_difficulty <= 0 do
      :ok
    else
      case NIP13.validate_pow(event, min_pow_difficulty,
             require_commitment: true,
             enforce_commitment: true
           ) do
        :ok -> :ok
        {:error, reason} -> {:error, map_pow_error(reason)}
      end
    end
  end

  defp map_pow_error(:missing_nonce_tag) do
    {:pow_missing_nonce_tag, "pow: missing nonce tag"}
  end

  defp map_pow_error(:missing_nonce_commitment) do
    {:pow_missing_nonce_commitment, "pow: missing nonce commitment"}
  end

  defp map_pow_error(:invalid_nonce_commitment) do
    {:pow_invalid_nonce_commitment, "pow: invalid nonce commitment"}
  end

  defp map_pow_error(:invalid_event_id) do
    {:pow_invalid_event_id, "pow: invalid event id"}
  end

  defp map_pow_error(:missing_event_id) do
    {:pow_invalid_event_id, "pow: invalid event id"}
  end

  defp map_pow_error({:insufficient_difficulty, actual, required}) do
    {:pow_insufficient_difficulty, "pow: difficulty #{actual} is less than #{required}"}
  end

  defp map_pow_error({:insufficient_commitment, committed, required}) do
    {:pow_insufficient_commitment, "pow: committed target #{committed} is less than #{required}"}
  end

  defp map_pow_error({:commitment_not_met, actual, committed}) do
    {:pow_commitment_not_met,
     "pow: difficulty #{actual} is less than committed target #{committed}"}
  end

  defp map_pow_error(_reason) do
    {:pow_rejected, "pow: event does not satisfy proof-of-work policy"}
  end

  defp validate_prefix_lengths(context, filters) do
    min_len = min_prefix_length()

    if min_len > 0 and Enum.any?(filters, &has_short_prefix?(&1, min_len)) do
      {:error, :prefix_too_short, Context.set_error(context, :prefix_too_short)}
    else
      {:ok, context}
    end
  end

  defp has_short_prefix?(%Filter{ids: ids, authors: authors}, min_len) do
    short_values?(ids, min_len) or short_values?(authors, min_len)
  end

  defp short_values?(nil, _min_len), do: false
  defp short_values?([], _min_len), do: false

  defp short_values?(values, min_len) when is_list(values) do
    Enum.any?(values, fn value ->
      len = byte_size(value)
      len < 64 and len < min_len
    end)
  end

  defp min_prefix_length do
    :nostr_relay
    |> Application.get_env(:relay_info, [])
    |> Keyword.get(:limits, %{})
    |> Map.get(:min_prefix_length, 0)
  end

  defp min_pow_difficulty do
    :nostr_relay
    |> Application.get_env(:relay_info, [])
    |> Keyword.get(:limits, %{})
    |> Map.get(:min_pow_difficulty, 0)
  end

  defp reject_event(context, event_id, reason, message) do
    context =
      context
      |> Context.add_frame(ok_frame(event_id, false, message))
      |> Context.set_error(reason)

    {:error, reason, context}
  end

  defp ok_frame(event_id, success?, message) do
    serialized =
      event_id
      |> event_id_for_ok()
      |> Message.ok(success?, message)
      |> Message.serialize()

    {:text, serialized}
  end

  defp event_id_for_ok(event_id) when is_binary(event_id), do: event_id
  defp event_id_for_ok(_event_id), do: ""
end
