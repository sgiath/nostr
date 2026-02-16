defmodule Nostr.Relay.Store.Behavior do
  @moduledoc "Behaviour for relay event store implementations."

  alias Nostr.Event
  alias Nostr.Filter

  @type insert_result() :: :ok | :duplicate | {:rejected, binary()} | {:error, term()}

  @callback insert_event(Event.t(), keyword()) :: insert_result()
  @callback query_events([Filter.t()], keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  @callback count_events([Filter.t()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback event_matches_filters?(String.t(), [Filter.t()], keyword()) :: boolean()
  @callback clear(keyword()) :: :ok
end
