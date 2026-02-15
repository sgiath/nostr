defmodule Nostr.Relay.Pipeline.Stages.MessageHandler do
  @moduledoc """
  Apply protocol effects for validated messages.

  Supported message types in this slice:

  - `EVENT`: validate and insert event, emit `OK`, and fan out to matching live
    subscriptions
  - `REQ`: query the store, emit replay frames and `EOSE`, then store subscription
  - `COUNT`: count matching events and emit count response
  - `CLOSE`: remove subscription
  - unknown: no-op

  Returns either updated `ConnectionState` or queued frames for engine finalization.
  """

  alias Nostr.Event
  alias Nostr.Message
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage
  alias Nostr.Relay.Store
  alias Nostr.Relay.Web.ConnectionState

  @behaviour Stage

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

  defp route_parsed_message({:event, %Event{} = event}, state, _raw_frame) do
    route_event(event, state)
  end

  defp route_parsed_message({:event, _sub_id, %Event{} = event}, state, _raw_frame) do
    route_event(event, state)
  end

  defp route_parsed_message({:req, sub_id, filters}, state, _raw_json)
       when is_binary(sub_id) and is_list(filters) do
    case Store.query_events(filters, scope: state.store_scope) do
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

  defp route_parsed_message({:count, sub_id, filters}, state, _raw_json)
       when is_binary(sub_id) and is_list(filters) do
    case Store.query_events(filters, scope: state.store_scope) do
      {:ok, events} ->
        count_frame =
          events
          |> length()
          |> Message.count(sub_id)
          |> Message.serialize()

        {:push, [{:text, count_frame}], state}

      {:error, _reason} ->
        notice = Message.notice("could not query events")
        {:push, [{:text, Message.serialize(notice)}], state}
    end
  end

  defp route_parsed_message({:close, sub_id}, state, _raw_json) when is_binary(sub_id) do
    {:ok, ConnectionState.remove_subscription(state, sub_id)}
  end

  defp route_parsed_message(_message, state, _raw_json), do: {:ok, state}

  defp route_event(%Event{} = event, %ConnectionState{} = state) do
    event_opts = [scope: state.store_scope]

    case Store.insert_event(event, event_opts) do
      :ok ->
        ok_message = Message.ok(event.id, true, "event accepted")

        match_frames =
          state.subscriptions
          |> Enum.filter(fn {_sub_id, filters} ->
            Store.event_matches_filters?(event.id, filters)
          end)
          |> Enum.map(fn {sub_id, _filters} ->
            {:text, Message.event(event, sub_id) |> Message.serialize()}
          end)

        {
          :push,
          [
            {
              :text,
              Message.serialize(ok_message)
            }
            | match_frames
          ],
          state
        }

      {:error, _reason} ->
        notice = Message.notice("could not store event")
        {:push, [{:text, Message.serialize(notice)}], state}
    end
  end
end
