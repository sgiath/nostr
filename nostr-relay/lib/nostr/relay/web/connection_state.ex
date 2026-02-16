defmodule Nostr.Relay.Web.ConnectionState do
  @moduledoc """
  Per-connection state tracked by the websocket transport.

   The relay protocol currently tracks message count, local subscriptions, and
   NIP-42 authentication state. Keeping this as a dedicated module avoids leaking
   state implementation details into callback modules and makes future relay
   expansion easier to test.
  """

  alias Nostr.Filter

  defstruct conn_id: "",
            messages: 0,
            subscriptions: %{},
            store_scope: :default,
            challenge: nil,
            authenticated_pubkeys: MapSet.new(),
            auth_required: false

  @type t() :: %__MODULE__{
          conn_id: binary(),
          messages: non_neg_integer(),
          subscriptions: %{optional(binary()) => [Filter.t()]},
          store_scope: term(),
          challenge: binary() | nil,
          authenticated_pubkeys: MapSet.t(binary()),
          auth_required: boolean()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    store_scope = Keyword.get(opts, :store_scope, :default)
    auth_required = Keyword.get(opts, :auth_required, false)
    conn_id = generate_conn_id()

    %__MODULE__{conn_id: conn_id, store_scope: store_scope, auth_required: auth_required}
  end

  defp generate_conn_id do
    :erlang.unique_integer([:positive])
    |> Integer.to_string(16)
    |> String.pad_leading(4, "0")
    |> String.slice(-4, 4)
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

  # -- Auth helpers (NIP-42) --------------------------------------------------

  @spec with_challenge(t(), binary()) :: t()
  def with_challenge(%__MODULE__{} = state, challenge) when is_binary(challenge) do
    %{state | challenge: challenge}
  end

  @spec authenticate_pubkey(t(), binary()) :: t()
  def authenticate_pubkey(%__MODULE__{} = state, pubkey) when is_binary(pubkey) do
    %{state | authenticated_pubkeys: MapSet.put(state.authenticated_pubkeys, pubkey)}
  end

  @spec authenticated?(t()) :: boolean()
  def authenticated?(%__MODULE__{authenticated_pubkeys: pubkeys}) do
    MapSet.size(pubkeys) > 0
  end

  @spec pubkey_authenticated?(t(), binary()) :: boolean()
  def pubkey_authenticated?(%__MODULE__{authenticated_pubkeys: pubkeys}, pubkey)
      when is_binary(pubkey) do
    MapSet.member?(pubkeys, pubkey)
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
