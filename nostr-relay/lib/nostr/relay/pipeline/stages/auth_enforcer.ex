defmodule Nostr.Relay.Pipeline.Stages.AuthEnforcer do
  @moduledoc """
  Gate stage that enforces NIP-42 authentication requirements.

  When `auth_required` is set on the connection state, this stage rejects all
  non-AUTH messages from unauthenticated clients with the appropriate
  `auth-required:` prefixed response:

  - `EVENT` → `OK(event_id, false, "auth-required: ...")`
  - `REQ`   → `CLOSED(sub_id, "auth-required: ...")`
  - `COUNT` → `CLOSED(sub_id, "auth-required: ...")`

  AUTH messages always pass through so `MessageHandler` can validate them.
  When auth is not required, or the client is already authenticated, this stage
  is a no-op pass-through.
  """

  alias Nostr.Event
  alias Nostr.Message
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage
  alias Nostr.Relay.Web.ConnectionState

  @behaviour Stage

  @auth_required_msg "auth-required: please authenticate"

  @impl Stage
  @spec call(Context.t(), keyword()) :: Stage.t()
  def call(%Context{connection_state: %ConnectionState{auth_required: false}} = context, _opts) do
    {:ok, context}
  end

  # AUTH messages always pass through
  def call(%Context{parsed_message: {:auth, _}} = context, _opts) do
    {:ok, context}
  end

  # Client is already authenticated — pass through
  def call(%Context{connection_state: state} = context, _opts) do
    if ConnectionState.authenticated?(state) do
      {:ok, context}
    else
      reject_unauthenticated(context)
    end
  end

  defp reject_unauthenticated(%Context{parsed_message: {:event, %Event{id: event_id}}} = context) do
    reject_with_ok(event_id, context)
  end

  defp reject_unauthenticated(
         %Context{parsed_message: {:event, _sub_id, %Event{id: event_id}}} = context
       ) do
    reject_with_ok(event_id, context)
  end

  defp reject_unauthenticated(%Context{parsed_message: {:req, sub_id, _}} = context) do
    reject_with_closed(sub_id, context)
  end

  defp reject_unauthenticated(%Context{parsed_message: {:count, sub_id, _}} = context) do
    reject_with_closed(sub_id, context)
  end

  # CLOSE and other messages pass through even when unauthenticated
  defp reject_unauthenticated(%Context{} = context) do
    {:ok, context}
  end

  defp reject_with_ok(event_id, %Context{} = context) do
    frame =
      {:text,
       event_id
       |> Message.ok(false, @auth_required_msg)
       |> Message.serialize()}

    context =
      context
      |> Context.add_frame(frame)
      |> Context.set_error(:auth_required)

    {:error, :auth_required, context}
  end

  defp reject_with_closed(sub_id, %Context{} = context) do
    frame =
      {:text,
       sub_id
       |> Message.closed(@auth_required_msg)
       |> Message.serialize()}

    context =
      context
      |> Context.add_frame(frame)
      |> Context.set_error(:auth_required)

    {:error, :auth_required, context}
  end
end
