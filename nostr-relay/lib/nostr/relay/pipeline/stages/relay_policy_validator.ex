defmodule Nostr.Relay.Pipeline.Stages.RelayPolicyValidator do
  @moduledoc """
  Relay policy gate for protocol constraints.

  This stage is intentionally permissive by default and currently passes all
  messages through. It is the extension point for auth, rate limits, and filter
  policy checks.
  """

  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage

  @behaviour Stage

  @impl Stage
  @spec call(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, atom(), Context.t()}
  def call(%Context{} = context, _options), do: {:ok, context}
end
