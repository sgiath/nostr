defmodule Nostr.Relay.Pipeline.Context do
  @moduledoc """
  Mutable request context that carries decoded message state through pipeline stages.

  The context is immutable data and is threaded through each stage. Each stage can
  update parsed payload, connection state, queued frames, and optional metadata.
  """

  alias Nostr.Relay.Web.ConnectionState

  defstruct raw_frame: nil,
            connection_state: nil,
            parsed_message: nil,
            frames: [],
            error: nil,
            meta: %{}

  @type t() :: %__MODULE__{
          raw_frame: binary(),
          connection_state: ConnectionState.t(),
          parsed_message: term(),
          frames: [{atom(), binary()}],
          error: atom() | nil,
          meta: map()
        }

  @spec new(binary(), ConnectionState.t()) :: t()
  def new(raw_frame, %ConnectionState{} = connection_state) when is_binary(raw_frame) do
    %__MODULE__{raw_frame: raw_frame, connection_state: connection_state}
  end

  @spec with_parsed_message(t(), term()) :: t()
  def with_parsed_message(%__MODULE__{} = context, parsed_message) do
    %{context | parsed_message: parsed_message}
  end

  @spec set_error(t(), atom()) :: t()
  def set_error(%__MODULE__{} = context, reason) when is_atom(reason) do
    %{context | error: reason}
  end

  @spec with_connection_state(t(), ConnectionState.t()) :: t()
  def with_connection_state(%__MODULE__{} = context, %ConnectionState{} = connection_state) do
    %{context | connection_state: connection_state}
  end

  @spec add_frames(t(), [{atom(), binary()}]) :: t()
  def add_frames(%__MODULE__{frames: frames} = context, new_frames)
      when is_list(new_frames) do
    %{context | frames: frames ++ new_frames}
  end

  @spec add_frame(t(), {atom(), binary()}) :: t()
  def add_frame(%__MODULE__{frames: frames} = context, frame) when is_tuple(frame) do
    %{context | frames: frames ++ [frame]}
  end

  @spec put_meta(t(), map()) :: t()
  def put_meta(%__MODULE__{} = context, meta) when is_map(meta) do
    %{context | meta: Map.merge(context.meta, meta)}
  end
end
