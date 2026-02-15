defmodule Nostr.Relay.Web.ConnectionState do
  @moduledoc """
  Per-connection state tracked by the websocket transport.

   The relay protocol currently tracks message count and local subscriptions.
   Keeping this as a dedicated module avoids leaking state implementation details
   into callback modules and makes future relay expansion easier to test.
  """

  alias Nostr.Filter

  defstruct messages: 0,
            subscriptions: %{},
            store_scope: :default

  @type t() :: %__MODULE__{
          messages: non_neg_integer(),
          subscriptions: %{optional(binary()) => [Filter.t()]},
          store_scope: term()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    store_scope = Keyword.get(opts, :store_scope, :default)

    %__MODULE__{store_scope: store_scope}
  end

  @spec inc_messages(t()) :: t()
  def inc_messages(%__MODULE__{messages: messages} = state) do
    %{state | messages: messages + 1}
  end

  @spec add_subscription(t(), binary()) :: t()
  @spec add_subscription(t(), binary(), [Filter.t()]) :: t()
  def add_subscription(%__MODULE__{} = state, sub_id) when is_binary(sub_id) do
    add_subscription(state, sub_id, [])
  end

  def add_subscription(%__MODULE__{} = state, sub_id, filters)
      when is_binary(sub_id) and is_list(filters) do
    %{state | subscriptions: Map.put(state.subscriptions, sub_id, filters)}
  end

  @spec remove_subscription(t(), binary()) :: t()
  def remove_subscription(%__MODULE__{} = state, sub_id) when is_binary(sub_id) do
    %{state | subscriptions: Map.delete(state.subscriptions, sub_id)}
  end

  @spec subscription_active?(t(), binary()) :: boolean()
  def subscription_active?(%__MODULE__{} = state, sub_id) when is_binary(sub_id) do
    Map.has_key?(state.subscriptions, sub_id)
  end

  @spec subscription_count(t()) :: non_neg_integer()
  def subscription_count(%__MODULE__{subscriptions: subscriptions}) do
    map_size(subscriptions)
  end

  @spec to_map(t()) :: %{
          messages: non_neg_integer(),
          subscriptions: %{optional(binary()) => [Filter.t()]},
          store_scope: term()
        }
  def to_map(%__MODULE__{} = state) do
    Map.from_struct(state)
  end
end
