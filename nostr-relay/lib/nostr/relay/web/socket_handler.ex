defmodule Nostr.Relay.Web.SocketHandler do
  @moduledoc """
  WebSocket callback module for one relay connection.

  This callback module is executed inside a single WebSocket handler process for the
  whole socket lifecycle. `SocketHandler` state is therefore scoped to a single
  incoming connection and can be extended for connection-specific subscription and
  backpressure tracking without introducing shared mutable state.

  Current behavior intentionally remains protocol-surface only:

  - ACK `EVENT` frames with `OK`
  - Track active `REQ` subscription IDs and filters
  - Replay matching stored events on `REQ` and emit `EOSE`
  - Dispatch accepted `EVENT`s to matching active subscriptions
  - Handle `CLOSE` by removing local subscription state
  - Reject invalid payloads with a `NOTICE`
  - NIP-42 AUTH challenge sent on every new connection
  - Ignore non-text frames for now (NIP-01 is JSON text based)
  """

  @behaviour WebSock

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Message
  alias Nostr.Relay.DebugLog
  alias Nostr.Relay.Web.ConnectionState
  alias Nostr.Relay.Web.MessageRouter

  @type t() :: ConnectionState.t()

  @impl WebSock
  @spec init(term()) :: {:push, [{:text, binary()}], t()}
  def init(_state) do
    Phoenix.PubSub.subscribe(Nostr.Relay.PubSub, "nostr:events")
    auth_config = Application.get_env(:nostr_relay, :auth, [])
    required = Keyword.get(auth_config, :required, false)

    challenge = generate_challenge()

    state =
      ConnectionState.new(auth_required: required)
      |> ConnectionState.with_challenge(challenge)

    if required do
      timeout = Keyword.get(auth_config, :timeout_seconds, 30) * 1_000
      Process.send_after(self(), :auth_timeout, timeout)
    end

    frame = {:text, Message.auth(challenge) |> Message.serialize()}
    {:push, [frame], state}
  end

  @impl WebSock
  @spec handle_in({binary(), keyword()}, t()) :: WebSock.handle_result()
  def handle_in({data, opcode: :text}, state) when is_binary(data) do
    DebugLog.log_in(state.conn_id, data)

    data
    |> MessageRouter.route_frame(state)
    |> log_outbound(state.conn_id)
  end

  def handle_in({_data, _}, state), do: {:ok, state}

  @impl WebSock
  @spec handle_info(term(), t()) ::
          {:ok, t()} | {:push, [{:text, binary()}], t()} | {:stop, :normal, term(), t()}
  def handle_info({:new_event, %Event{} = event}, state) do
    frames =
      state.subscriptions
      |> Enum.filter(fn {_sub_id, filters} -> Filter.any_match?(filters, event) end)
      |> Enum.map(fn {sub_id, _filters} ->
        serialized =
          event
          |> Message.event(sub_id)
          |> Message.serialize()

        {:text, serialized}
      end)

    case frames do
      [] ->
        {:ok, state}

      frames ->
        DebugLog.log_out(state.conn_id, frames)
        {:push, frames, state}
    end
  end

  def handle_info(:auth_timeout, state) do
    if state.auth_required and not ConnectionState.authenticated?(state) do
      {:stop, :normal, {4000, "auth-required: authentication timeout"}, state}
    else
      {:ok, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  @spec terminate(any(), t()) :: :ok
  def terminate(_reason, _state), do: :ok

  defp generate_challenge do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  defp log_outbound({:push, frames, _state} = result, conn_id) do
    DebugLog.log_out(conn_id, frames)
    result
  end

  defp log_outbound(result, _conn_id), do: result
end
