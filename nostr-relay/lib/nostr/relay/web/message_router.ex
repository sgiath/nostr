defmodule Nostr.Relay.Web.MessageRouter do
  @moduledoc """
  Protocol routing helper for incoming websocket payloads.

  The module is transport-agnostic. Socket callbacks delegate text frames here and
  apply returned `WebSock` actions.

  All protocol parsing and dispatching is implemented by
  `Nostr.Relay.Pipeline.Engine`, which executes a configurable stage pipeline.
  """

  alias Nostr.Relay.Pipeline.Engine
  alias Nostr.Relay.Web.ConnectionState

  @spec route_frame(binary(), ConnectionState.t()) :: WebSock.handle_result()
  def route_frame(data, %ConnectionState{} = state) when is_binary(data) do
    Engine.run(data, state)
  end
end
