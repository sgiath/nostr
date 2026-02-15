defmodule Nostr.Relay.Web.ConnectionState do
  @moduledoc """
  Per-connection state tracked by the websocket transport.

  The relay protocol currently tracks only message count and local subscriptions.
  Keeping this as a dedicated module avoids leaking state implementation details
  into callback modules and makes future relay expansion easier to test.
  """

  alias MapSet

  defstruct messages: 0,
            subscriptions: MapSet.new()

  @type t() :: %__MODULE__{
          messages: non_neg_integer(),
          subscriptions: MapSet.t(binary())
        }

  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @spec inc_messages(t()) :: t()
  def inc_messages(%__MODULE__{messages: messages} = state) do
    %{state | messages: messages + 1}
  end

  @spec add_subscription(t(), binary()) :: t()
  def add_subscription(%__MODULE__{} = state, sub_id) when is_binary(sub_id) do
    %{state | subscriptions: MapSet.put(state.subscriptions, sub_id)}
  end

  @spec remove_subscription(t(), binary()) :: t()
  def remove_subscription(%__MODULE__{} = state, sub_id) when is_binary(sub_id) do
    %{state | subscriptions: MapSet.delete(state.subscriptions, sub_id)}
  end

  @spec subscription_active?(t(), binary()) :: boolean()
  def subscription_active?(%__MODULE__{} = state, sub_id) when is_binary(sub_id) do
    MapSet.member?(state.subscriptions, sub_id)
  end

  @spec subscription_count(t()) :: non_neg_integer()
  def subscription_count(%__MODULE__{subscriptions: subscriptions}) do
    MapSet.size(subscriptions)
  end

  @spec to_map(t()) :: %{messages: non_neg_integer(), subscriptions: MapSet.t(binary())}
  def to_map(%__MODULE__{} = state) do
    Map.from_struct(state)
  end
end
