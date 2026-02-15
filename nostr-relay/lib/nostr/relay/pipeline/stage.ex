defmodule Nostr.Relay.Pipeline.Stage do
  @moduledoc """
  Behaviour contract for every pipeline stage.

  A stage receives the current `Context` and handler options and returns either:

  - `{:ok, context}` to continue
  - `{:error, reason, context}` to stop and respond with a protocol notice
  """

  alias Nostr.Relay.Pipeline.Context

  @type t() :: {:ok, Context.t()} | {:error, atom(), Context.t()}

  @callback call(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, atom(), Context.t()}
end
