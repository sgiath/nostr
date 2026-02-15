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
  - Ignore non-text frames for now (NIP-01 is JSON text based)
  """

  @behaviour WebSock

  alias Nostr.Relay.Web.ConnectionState
  alias Nostr.Relay.Web.MessageRouter

  @type t() :: ConnectionState.t()

  @impl WebSock
  @spec init(term()) :: {:ok, t()}
  def init(_state) do
    {:ok, ConnectionState.new()}
  end

  @impl WebSock
  @spec handle_in({binary(), keyword()}, t()) :: WebSock.handle_result()
  def handle_in({data, opcode: :text}, state) when is_binary(data),
    do: MessageRouter.route_frame(data, state)

  def handle_in({_data, _}, state), do: {:ok, state}

  @impl WebSock
  @spec handle_info(term(), t()) :: {:ok, t()}
  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  @spec terminate(any(), t()) :: :ok
  def terminate(_reason, _state), do: :ok
end
