defmodule Nostr.Relay.Web.MessageRouter do
  @moduledoc """
  Protocol routing helper for parsed Nostr frames.

  This module is intentionally transport-agnostic. The socket callback only delegates
  text frames here and applies returned WebSock actions.
  """

  alias Nostr.Event
  alias Nostr.Message
  alias Nostr.Relay.Web.ConnectionState

  @type parsed_action() ::
          :ok
          | {:close, binary()}
          | {:subscribe, binary()}
          | {:push, [{binary(), keyword()}]}

  @spec route_frame(binary(), ConnectionState.t()) :: WebSock.handle_result()
  def route_frame(data, %ConnectionState{} = state) when is_binary(data) do
    state
    |> ConnectionState.inc_messages()
    |> parse_and_route(data)
  end

  defp parse_and_route(state, data) when is_binary(data) do
    case parse_nostr_message(data) do
      {:ok, message} ->
        message
        |> route_parsed_message()
        |> apply_action(state)

      {:error, :invalid_message} ->
        notice = Message.notice("invalid message format")
        {:push, [{:text, Message.serialize(notice)}], state}
    end
  end

  defp route_parsed_message({:event, %Event{} = event}) do
    ok_message = Message.ok(event.id, true, "event accepted")

    {
      :push,
      [
        {
          :text,
          Message.serialize(ok_message)
        }
      ]
    }
  end

  defp route_parsed_message({:event, _sub_id, %Event{} = event}) do
    ok_message = Message.ok(event.id, true, "event accepted")

    {
      :push,
      [
        {
          :text,
          Message.serialize(ok_message)
        }
      ]
    }
  end

  defp route_parsed_message({:req, sub_id, _filters}) do
    {:subscribe, sub_id}
  end

  defp route_parsed_message({:close, sub_id}) do
    {:close, sub_id}
  end

  defp route_parsed_message(_message) do
    :ok
  end

  defp apply_action({:push, frames}, state) when is_list(frames) do
    {:push, frames, state}
  end

  defp apply_action({:subscribe, sub_id}, state) when is_binary(sub_id) do
    updated_state = ConnectionState.add_subscription(state, sub_id)
    eose_message = Message.eose(sub_id)
    {:push, [{:text, Message.serialize(eose_message)}], updated_state}
  end

  defp apply_action({:close, sub_id}, state) when is_binary(sub_id) do
    {:ok, ConnectionState.remove_subscription(state, sub_id)}
  end

  defp apply_action(:ok, state), do: {:ok, state}

  defp parse_nostr_message(data) when is_binary(data) do
    case safe_parse_nostr(data) do
      :error -> {:error, :invalid_message}
      message -> {:ok, message}
    end
  end

  defp safe_parse_nostr(data) do
    try do
      Message.parse(data)
    rescue
      _ -> :error
    end
  end
end
