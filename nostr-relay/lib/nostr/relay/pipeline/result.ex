defmodule Nostr.Relay.Pipeline.Result do
  @moduledoc """
  Shared result shape for pipeline stage execution and stage transition outcomes.

  Public helpers in this area return:
  - `{:ok, %Context{}}` when stage processing succeeds
  - `{:error, reason, %Context{}}` when processing should stop with a notice
  """

  alias Nostr.Relay.Pipeline.Context

  @type t() :: {:ok, Context.t()} | {:error, atom(), Context.t()}
end
