defmodule Nostr.Auth.ReplayCache do
  @moduledoc """
  Replay-check callback contract for NIP-98 events.

  Implementations should atomically decide whether an event ID is acceptable
  according to the adapter's replay policy.
  """

  alias Nostr.Event

  @doc """
  Checks replay state for an event and stores it when accepted.

  Returns `:ok` when the event is accepted, or `{:error, reason}` when replay
  checks fail.
  """
  @callback check_and_store(Event.t(), keyword()) :: :ok | {:error, term()}
end
