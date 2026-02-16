defmodule Nostr.Relay.Groups do
  @moduledoc false

  alias Nostr.Event
  alias Nostr.Relay.Groups.Authorization
  alias Nostr.Relay.Groups.Projection
  alias Nostr.Relay.Groups.Visibility

  @spec enabled?() :: boolean()
  def enabled? do
    :nostr_relay
    |> Application.get_env(:nip29, [])
    |> Keyword.get(:enabled, false)
  end

  @spec options() :: keyword()
  def options do
    Application.get_env(:nostr_relay, :nip29, [])
  end

  @spec authorize_write(Event.t(), [binary()]) :: :ok | {:error, binary()}
  def authorize_write(%Event{} = event, authenticated_pubkeys)
      when is_list(authenticated_pubkeys) do
    Authorization.authorize_event(event, authenticated_pubkeys, options())
  end

  @spec apply_projection(Event.t()) :: :ok | {:error, term()}
  def apply_projection(%Event{} = event) do
    Projection.apply_event(event, options())
  end

  @spec event_visible?(Event.t(), [binary()]) :: boolean()
  def event_visible?(%Event{} = event, authenticated_pubkeys)
      when is_list(authenticated_pubkeys) do
    Visibility.visible?(event, authenticated_pubkeys, options())
  end
end
