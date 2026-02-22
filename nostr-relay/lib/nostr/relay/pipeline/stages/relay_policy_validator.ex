defmodule Nostr.Relay.Pipeline.Stages.RelayPolicyValidator do
  @moduledoc """
  Relay policy gate for protocol constraints.

  Current checks:

  - `max_subscriptions` — rejects REQ messages that would exceed the configured
    number of active subscription IDs for the websocket connection.
  - `max_event_tags` — rejects EVENT messages whose tag count exceeds the
    configured maximum.
  - `max_content_length` — rejects EVENT messages whose content length exceeds
    the configured maximum.
  - `max_subid_length` — rejects REQ/COUNT/CLOSE messages where `sub_id`
    exceeds the configured maximum length.
  - `min_pow_difficulty` — when greater than zero, rejects EVENT messages that
    do not satisfy NIP-13 PoW and nonce difficulty commitment requirements.
  - `min_prefix_length` — rejects REQ/COUNT filters where `ids` or `authors`
    contain prefix values shorter than the configured minimum. Full 64-character
    hex IDs are always accepted regardless of this setting.
  - `max_limit` — clamps REQ/COUNT filter `limit` values to the configured
    maximum when present.
  - `default_limit` — sets REQ/COUNT filter `limit` when omitted.
  """

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Message
  alias Nostr.NIP13
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage
  alias Nostr.Relay.Web.ConnectionState

  @behaviour Stage

  @default_max_subscriptions 100
  @default_max_event_tags 100
  @default_max_content_length 8_192
  @max_subscriptions_reached_msg "restricted: max subscriptions reached"
  @max_event_tags_exceeded_msg "restricted: max event tags exceeded"
  @max_content_length_exceeded_msg "restricted: max content length exceeded"
  @created_at_lower_limit_exceeded_msg "invalid: created_at is too old"
  @created_at_upper_limit_exceeded_msg "invalid: created_at is too far in the future"

  @impl Stage
  @spec call(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, atom(), Context.t()}
  def call(%Context{parsed_message: parsed_message} = context, _options) do
    case parsed_message do
      {:event, %Event{} = event} ->
        validate_event_policies(context, event)

      {:event, _sub_id, %Event{} = event} ->
        validate_event_policies(context, event)

      {:req, sub_id, filters} when is_binary(sub_id) and is_list(filters) ->
        validate_req_policies(context, sub_id, filters)

      {:count, sub_id, filters} when is_binary(sub_id) and is_list(filters) ->
        validate_count_policies(context, sub_id, filters)

      {:close, sub_id} when is_binary(sub_id) ->
        validate_close_policies(context, sub_id)

      _other ->
        {:ok, context}
    end
  end

  defp validate_req_policies(context, sub_id, filters) do
    with {:ok, %Context{} = context} <- validate_subid_length(context, sub_id),
         {:ok, %Context{} = context} <- validate_max_subscriptions(context, sub_id),
         {:ok, %Context{} = context} <- validate_prefix_lengths(context, filters) do
      {:ok, with_clamped_filters(context, :req, sub_id, filters)}
    end
  end

  defp validate_count_policies(context, sub_id, filters) do
    with {:ok, %Context{} = context} <- validate_subid_length(context, sub_id),
         {:ok, %Context{} = context} <- validate_prefix_lengths(context, filters) do
      {:ok, with_clamped_filters(context, :count, sub_id, filters)}
    end
  end

  defp validate_close_policies(context, sub_id) do
    validate_subid_length(context, sub_id)
  end

  defp validate_subid_length(%Context{} = context, sub_id) when is_binary(sub_id) do
    max_len = max_subid_length()

    if max_len > 0 and byte_size(sub_id) > max_len do
      {:error, :subid_too_long, Context.set_error(context, :subid_too_long)}
    else
      {:ok, context}
    end
  end

  defp with_clamped_filters(%Context{} = context, message_type, sub_id, filters)
       when message_type in [:req, :count] and is_binary(sub_id) and is_list(filters) do
    parsed_message = {message_type, sub_id, apply_filter_limits(filters)}
    Context.with_parsed_message(context, parsed_message)
  end

  defp validate_max_subscriptions(%Context{connection_state: state} = context, sub_id)
       when is_binary(sub_id) do
    if subscription_allowed?(state, sub_id) do
      {:ok, context}
    else
      context =
        context
        |> Context.add_frame(closed_frame(sub_id, @max_subscriptions_reached_msg))
        |> Context.set_error(:too_many_subscriptions)

      {:error, :too_many_subscriptions, context}
    end
  end

  defp subscription_allowed?(%ConnectionState{} = state, sub_id) when is_binary(sub_id) do
    max = max_subscriptions()

    ConnectionState.subscription_active?(state, sub_id) or
      ConnectionState.subscription_count(state) < max
  end

  defp validate_event_policies(context, event) do
    with :ok <- validate_created_at_window_policy(event),
         :ok <- validate_pow_policy(event),
         :ok <- validate_max_event_tags_policy(event),
         :ok <- validate_max_content_length_policy(event) do
      {:ok, context}
    else
      {:error, {reason, message}} ->
        reject_event(context, event.id, reason, message)
    end
  end

  defp validate_created_at_window_policy(%Event{created_at: %DateTime{} = created_at}) do
    now = DateTime.utc_now()

    with :ok <- validate_created_at_lower_limit(created_at, now) do
      validate_created_at_upper_limit(created_at, now)
    end
  end

  defp validate_created_at_window_policy(_event), do: :ok

  defp validate_created_at_lower_limit(%DateTime{} = created_at, %DateTime{} = now) do
    lower_limit = created_at_lower_limit()

    if lower_limit > 0 and DateTime.diff(now, created_at, :second) > lower_limit do
      {:error, {:created_at_lower_limit_exceeded, @created_at_lower_limit_exceeded_msg}}
    else
      :ok
    end
  end

  defp validate_created_at_upper_limit(%DateTime{} = created_at, %DateTime{} = now) do
    upper_limit = created_at_upper_limit()

    if upper_limit > 0 and DateTime.diff(created_at, now, :second) > upper_limit do
      {:error, {:created_at_upper_limit_exceeded, @created_at_upper_limit_exceeded_msg}}
    else
      :ok
    end
  end

  defp validate_max_event_tags_policy(%Event{tags: tags}) when is_list(tags) do
    max_tags = max_event_tags()

    if length(tags) > max_tags do
      {:error, {:too_many_event_tags, @max_event_tags_exceeded_msg}}
    else
      :ok
    end
  end

  defp validate_max_event_tags_policy(_event), do: :ok

  defp validate_max_content_length_policy(%Event{content: content}) when is_binary(content) do
    max_len = max_content_length()

    if String.length(content) > max_len do
      {:error, {:content_too_long, @max_content_length_exceeded_msg}}
    else
      :ok
    end
  end

  defp validate_max_content_length_policy(_event), do: :ok

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

  defp apply_filter_limits(filters) when is_list(filters) do
    max_limit = max_limit()
    default_limit = default_limit()

    Enum.map(filters, &apply_filter_limit(&1, default_limit, max_limit))
  end

  defp apply_filter_limit(%Filter{} = filter, default_limit, max_limit) do
    filter
    |> maybe_apply_default_limit(default_limit)
    |> maybe_clamp_filter_limit(max_limit)
  end

  defp maybe_apply_default_limit(%Filter{limit: nil} = filter, default_limit)
       when is_integer(default_limit) and default_limit >= 0 do
    %{filter | limit: default_limit}
  end

  defp maybe_apply_default_limit(%Filter{} = filter, _default_limit), do: filter

  defp maybe_clamp_filter_limit(%Filter{limit: limit} = filter, max_limit)
       when is_integer(limit) and is_integer(max_limit) and max_limit >= 0 and limit > max_limit do
    %{filter | limit: max_limit}
  end

  defp maybe_clamp_filter_limit(%Filter{} = filter, _max_limit), do: filter

  defp min_prefix_length do
    :nostr_relay
    |> Application.get_env(:relay_policy, [])
    |> Keyword.get(:min_prefix_length, 0)
  end

  defp max_subscriptions do
    case limitation_max_subscriptions() do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> @default_max_subscriptions
    end
  end

  defp limitation_max_subscriptions do
    :nostr_relay
    |> Application.get_env(:relay_info, [])
    |> Keyword.get(:limitation, %{})
    |> Map.get(:max_subscriptions)
  end

  defp max_subid_length do
    case limitation_max_subid_length() do
      value when is_integer(value) and value > 0 -> value
      _invalid -> 0
    end
  end

  defp limitation_max_subid_length do
    :nostr_relay
    |> Application.get_env(:relay_info, [])
    |> Keyword.get(:limitation, %{})
    |> Map.get(:max_subid_length)
  end

  defp min_pow_difficulty do
    :nostr_relay
    |> Application.get_env(:relay_info, [])
    |> Keyword.get(:limitation, %{})
    |> Map.get(:min_pow_difficulty, 0)
  end

  defp max_limit do
    case limitation_max_limit() do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> nil
    end
  end

  defp default_limit do
    case limitation_default_limit() do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> nil
    end
  end

  defp max_event_tags do
    case limitation_max_event_tags() do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> @default_max_event_tags
    end
  end

  defp max_content_length do
    case limitation_max_content_length() do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> @default_max_content_length
    end
  end

  defp created_at_lower_limit do
    case limitation_created_at_lower_limit() do
      value when is_integer(value) and value > 0 -> value
      _invalid -> 0
    end
  end

  defp created_at_upper_limit do
    case limitation_created_at_upper_limit() do
      value when is_integer(value) and value > 0 -> value
      _invalid -> 0
    end
  end

  defp limitation_max_limit do
    :nostr_relay
    |> Application.get_env(:relay_info, [])
    |> Keyword.get(:limitation, %{})
    |> Map.get(:max_limit)
  end

  defp limitation_default_limit do
    :nostr_relay
    |> Application.get_env(:relay_info, [])
    |> Keyword.get(:limitation, %{})
    |> Map.get(:default_limit)
  end

  defp limitation_max_event_tags do
    :nostr_relay
    |> Application.get_env(:relay_info, [])
    |> Keyword.get(:limitation, %{})
    |> Map.get(:max_event_tags)
  end

  defp limitation_max_content_length do
    :nostr_relay
    |> Application.get_env(:relay_info, [])
    |> Keyword.get(:limitation, %{})
    |> Map.get(:max_content_length)
  end

  defp limitation_created_at_lower_limit do
    :nostr_relay
    |> Application.get_env(:relay_info, [])
    |> Keyword.get(:limitation, %{})
    |> Map.get(:created_at_lower_limit)
  end

  defp limitation_created_at_upper_limit do
    :nostr_relay
    |> Application.get_env(:relay_info, [])
    |> Keyword.get(:limitation, %{})
    |> Map.get(:created_at_upper_limit)
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

  defp closed_frame(sub_id, message) do
    serialized =
      sub_id
      |> Message.closed(message)
      |> Message.serialize()

    {:text, serialized}
  end
end
