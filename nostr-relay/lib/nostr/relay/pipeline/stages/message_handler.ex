defmodule Nostr.Relay.Pipeline.Stages.MessageHandler do
  @moduledoc """
  Apply protocol effects for validated messages.

  Supported message types in this slice:

  - `EVENT`: validate and insert event, emit `OK`, and broadcast to PubSub for
    cross-connection fan-out
  - `REQ`: query the store, emit replay frames and `EOSE`, then store subscription
  - `COUNT`: count matching events and emit count response
  - `CLOSE`: remove subscription
  - `AUTH`: validate NIP-42 auth event, authenticate pubkey, emit `OK`
  - unknown: no-op

  Returns either updated `ConnectionState` or queued frames for engine finalization.
  """

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Message
  alias Nostr.NIP29
  alias Nostr.Tag
  alias Nostr.Relay.Groups
  alias Nostr.Relay.Groups.RelayEvents
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage
  alias Nostr.Relay.Replacement
  alias Nostr.Relay.Store
  alias Nostr.Relay.Store.QueryBuilder
  alias Nostr.Relay.Web.ConnectionState

  @behaviour Stage

  @auth_timestamp_window_seconds 600

  @impl Stage
  @spec call(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, atom(), Context.t()}
  def call(
        %Context{parsed_message: parsed_message, raw_frame: raw_frame, connection_state: state} =
          context,
        _options
      )
      when is_binary(raw_frame) do
    parsed_message
    |> route_parsed_message(state, raw_frame)
    |> route_result(context)
  end

  def call(context, _options), do: {:ok, context}

  defp route_result({:ok, %ConnectionState{} = new_state}, context) do
    {:ok, Context.with_connection_state(context, new_state)}
  end

  defp route_result({:push, frames, %ConnectionState{} = new_state}, context) do
    context
    |> Context.with_connection_state(new_state)
    |> Context.add_frames(frames)
    |> then(&{:ok, &1})
  end

  defp route_result(_result, context), do: {:error, :handler_error, context}

  # -- AUTH (NIP-42) -----------------------------------------------------------

  defp route_parsed_message({:auth, %Event{kind: 22_242} = event}, state, _raw_frame) do
    route_auth(event, state)
  end

  # AUTH with wrong event kind — reject with OK
  defp route_parsed_message({:auth, %Event{} = event}, state, _raw_frame) do
    {:push, [ok_frame(event.id, false, "auth-required: invalid auth event kind")], state}
  end

  # Relay-to-client AUTH challenge echoed back — ignore gracefully
  defp route_parsed_message({:auth, challenge}, state, _raw_frame) when is_binary(challenge) do
    {:ok, state}
  end

  # -- EVENT -------------------------------------------------------------------

  defp route_parsed_message({:event, %Event{} = event}, state, _raw_frame) do
    route_event(event, state)
  end

  defp route_parsed_message({:event, _sub_id, %Event{} = event}, state, _raw_frame) do
    route_event(event, state)
  end

  # -- REQ ---------------------------------------------------------------------

  defp route_parsed_message({:req, sub_id, filters}, state, _raw_json)
       when is_binary(sub_id) and is_list(filters) do
    query_opts = [
      scope: state.store_scope,
      gift_wrap_recipients: MapSet.to_list(state.authenticated_pubkeys),
      group_viewer_pubkeys: MapSet.to_list(state.authenticated_pubkeys)
    ]

    case Store.query_events(filters, query_opts) do
      {:ok, events} ->
        event_frames =
          Enum.map(events, fn event ->
            {:text, Message.serialize(Message.event(event, sub_id))}
          end)

        eose_message = Message.eose(sub_id)
        eose_frame = {:text, Message.serialize(eose_message)}

        {:push, event_frames ++ [eose_frame],
         ConnectionState.add_subscription(state, sub_id, filters)}

      {:error, _reason} ->
        notice = Message.notice("could not query events")
        {:push, [{:text, Message.serialize(notice)}], state}
    end
  end

  # -- COUNT -------------------------------------------------------------------

  defp route_parsed_message({:count, sub_id, filters}, state, _raw_json)
       when is_binary(sub_id) and is_list(filters) do
    query_opts = [
      scope: state.store_scope,
      gift_wrap_recipients: MapSet.to_list(state.authenticated_pubkeys),
      group_viewer_pubkeys: MapSet.to_list(state.authenticated_pubkeys)
    ]

    case Store.count_events(filters, query_opts) do
      {:ok, count} ->
        count_frame =
          count
          |> Message.count(sub_id)
          |> Message.serialize()

        {:push, [{:text, count_frame}], state}

      {:error, _reason} ->
        notice = Message.notice("could not query events")
        {:push, [{:text, Message.serialize(notice)}], state}
    end
  end

  # -- CLOSE -------------------------------------------------------------------

  defp route_parsed_message({:close, sub_id}, state, _raw_json) when is_binary(sub_id) do
    {:ok, ConnectionState.remove_subscription(state, sub_id)}
  end

  defp route_parsed_message(_message, state, _raw_json), do: {:ok, state}

  # -- AUTH validation ---------------------------------------------------------

  defp route_auth(%Event{} = event, %ConnectionState{} = state) do
    with :ok <- validate_auth_timestamp(event),
         :ok <- validate_auth_challenge(event, state),
         :ok <- validate_auth_relay(event),
         :ok <- check_access_list(event) do
      new_state = ConnectionState.authenticate_pubkey(state, event.pubkey)
      {:push, [ok_frame(event.id, true, "")], new_state}
    else
      {:error, message} ->
        {:push, [ok_frame(event.id, false, message)], state}
    end
  end

  defp validate_auth_timestamp(%Event{created_at: created_at}) do
    now = DateTime.utc_now()
    diff = abs(DateTime.diff(now, created_at, :second))

    if diff <= @auth_timestamp_window_seconds do
      :ok
    else
      {:error, "auth-required: event too old"}
    end
  end

  defp validate_auth_challenge(%Event{} = event, %ConnectionState{challenge: challenge}) do
    event_challenge = get_tag_data(event, :challenge)

    cond do
      is_nil(challenge) ->
        {:error, "auth-required: no challenge issued"}

      event_challenge == challenge ->
        :ok

      true ->
        {:error, "auth-required: challenge mismatch"}
    end
  end

  defp validate_auth_relay(%Event{} = event) do
    event_relay = get_tag_data(event, :relay)
    configured_url = resolve_relay_url()

    cond do
      is_nil(configured_url) ->
        # No relay URL configured and cannot derive one — skip validation
        :ok

      is_nil(event_relay) ->
        {:error, "auth-required: relay URL mismatch"}

      relay_domain_match?(event_relay, configured_url) ->
        :ok

      true ->
        {:error, "auth-required: relay URL mismatch"}
    end
  end

  defp resolve_relay_url do
    relay_info = Application.get_env(:nostr_relay, :relay_info, [])

    case Keyword.get(relay_info, :url) do
      nil -> derive_relay_url()
      url -> url
    end
  end

  defp derive_relay_url do
    server = Application.get_env(:nostr_relay, :server, [])
    ip = Keyword.get(server, :ip)
    port = Keyword.get(server, :port)
    scheme = if Keyword.get(server, :scheme) == :https, do: "wss", else: "ws"

    case {ip, port} do
      {nil, _} -> nil
      {_, nil} -> nil
      {ip, port} -> "#{scheme}://#{format_ip(ip)}:#{port}"
    end
  end

  defp format_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> List.to_string()
  defp format_ip(ip) when is_binary(ip), do: ip

  defp check_access_list(%Event{pubkey: pubkey}) do
    auth_config = Application.get_env(:nostr_relay, :auth, [])
    mode = Keyword.get(auth_config, :mode, :none)

    case mode do
      :whitelist ->
        whitelist = Keyword.get(auth_config, :whitelist, [])

        if pubkey in whitelist,
          do: :ok,
          else: {:error, "restricted: not on whitelist"}

      :denylist ->
        denylist = Keyword.get(auth_config, :denylist, [])

        if pubkey in denylist,
          do: {:error, "restricted: pubkey denied"},
          else: :ok

      _ ->
        :ok
    end
  end

  defp relay_domain_match?(event_relay, configured_url) do
    event_host = URI.parse(event_relay).host
    config_host = URI.parse(configured_url).host

    event_host != nil and event_host == config_host
  end

  defp get_tag_data(%Event{tags: tags}, tag_type) do
    case Enum.find(tags, &(&1.type == tag_type)) do
      nil -> nil
      tag -> tag.data
    end
  end

  # -- EVENT handling ----------------------------------------------------------

  defp route_event(%Event{kind: 22_242} = event, %ConnectionState{} = state) do
    {:push, [ok_frame(event.id, false, "blocked: kind 22242 not accepted via EVENT")], state}
  end

  defp route_event(%Event{} = event, %ConnectionState{} = state) do
    route_event_store(event, state)
  end

  defp route_event_store(%Event{} = event, %ConnectionState{} = state) do
    event_opts = [scope: state.store_scope]
    is_deleted = QueryBuilder.event_deleted?(event)

    case Store.insert_event(event, event_opts) do
      :ok ->
        :ok = maybe_handle_group_side_effects(event)

        Phoenix.PubSub.broadcast(Nostr.Relay.PubSub, "nostr:events", {:new_event, event})

        {:push, [stored_event_ack_frame(event, is_deleted, state.store_scope)], state}

      :duplicate ->
        ok_frame = duplicate_event_ack_frame(event, is_deleted, state.store_scope)

        {:push, [ok_frame], state}

      {:error, _reason} ->
        ok_frame = ok_frame(event.id, false, "error: could not store event")
        {:push, [ok_frame], state}
    end
  end

  defp maybe_handle_group_side_effects(%Event{kind: 9_022} = event) do
    with true <- Groups.enabled?(),
         group_id when is_binary(group_id) <- NIP29.group_id_from_h(event),
         {:ok, relay_event} <-
           RelayEvents.auto_remove_user_event(group_id, event.pubkey, "removed by leave request"),
         :ok <- Store.insert_event(relay_event, []) do
      Phoenix.PubSub.broadcast(Nostr.Relay.PubSub, "nostr:events", {:new_event, relay_event})
      :ok
    else
      _ -> :ok
    end
  end

  defp maybe_handle_group_side_effects(_event), do: :ok

  defp stored_event_ack_frame(%Event{} = event, true, _scope),
    do: ok_frame(event.id, false, "rejected: event is deleted")

  defp stored_event_ack_frame(%Event{} = event, false, scope),
    do: replacement_event_ack_frame(event, scope)

  defp duplicate_event_ack_frame(%Event{} = event, true, _scope),
    do: ok_frame(event.id, false, "rejected: event is deleted")

  defp duplicate_event_ack_frame(%Event{} = event, false, scope) do
    if replacement_event_stale?(event, scope) do
      ok_frame(event.id, false, "rejected: stale replacement event")
    else
      ok_frame(event.id, true, "duplicate: already have this event")
    end
  end

  defp replacement_event_ack_frame(%Event{} = event, store_scope) do
    if replacement_event_stale?(event, store_scope) do
      ok_frame(event.id, false, "rejected: stale replacement event")
    else
      ok_frame(event.id, true, "")
    end
  end

  defp replacement_event_stale?(%Event{} = event, scope) do
    case Replacement.replacement_type(event.kind) do
      :regular ->
        false

      replacement_type ->
        filter = %Filter{authors: [event.pubkey], kinds: [event.kind]}

        case Store.query_events([filter], scope: scope) do
          {:ok, events} ->
            other_events = Enum.reject(events, &(&1.id == event.id))

            case matching_replacement_event(event, replacement_type, other_events) do
              nil ->
                false

              existing ->
                not newer_replacement?(event, existing)
            end

          {:error, _reason} ->
            false
        end
    end
  end

  defp matching_replacement_event(_event, :replaceable, events) when is_list(events) do
    List.first(events)
  end

  defp matching_replacement_event(%Event{} = event, :parameterized, events)
       when is_list(events) do
    incoming_d = replacement_d_tag(event)

    Enum.find(events, fn candidate -> replacement_d_tag(candidate) == incoming_d end)
  end

  defp matching_replacement_event(_event, :regular, _events), do: nil

  defp newer_replacement?(%Event{} = candidate, %Event{} = existing) do
    candidate_created_at = DateTime.to_unix(candidate.created_at)
    existing_created_at = DateTime.to_unix(existing.created_at)

    candidate_created_at > existing_created_at or
      (candidate_created_at == existing_created_at and candidate.id < existing.id)
  end

  defp replacement_d_tag(%Event{} = event) do
    replacement_d_tag(event.tags)
  end

  defp replacement_d_tag(tags) when is_list(tags) do
    tags
    |> Enum.find_value(fn
      %Tag{type: :d, data: data} when is_binary(data) -> data
      _ -> nil
    end)
    |> Kernel.||("")
  end

  defp replacement_d_tag(_tags), do: ""

  defp ok_frame(event_id, success?, message) do
    serialized =
      event_id
      |> Message.ok(success?, message)
      |> Message.serialize()

    {:text, serialized}
  end
end
