defmodule Nostr.Relay.Store.Behavior do
  @moduledoc "Behaviour for relay event store implementations."

  alias Nostr.Event
  alias Nostr.Filter

  @callback insert_event(Event.t(), keyword()) :: :ok | {:error, term()}
  @callback query_events([Filter.t()], keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  @callback event_matches_filters?(String.t(), [Filter.t()], keyword()) :: boolean()
  @callback clear(keyword()) :: :ok
end
