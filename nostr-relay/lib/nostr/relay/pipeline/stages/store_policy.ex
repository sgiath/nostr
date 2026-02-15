defmodule Nostr.Relay.Pipeline.Stages.StorePolicy do
  @moduledoc """
  Store policy and post-processing hook.

  Kept as a pass-through placeholder while storage rules evolve. Future revisions
  can enforce size limits, retention policy, spam checks, or per-event limits here.
  """

  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage

  @behaviour Stage

  @impl Stage
  @spec call(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, atom(), Context.t()}
  def call(%Context{} = context, _options), do: {:ok, context}
end
