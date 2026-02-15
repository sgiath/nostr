defmodule Nostr.Relay.Pipeline.Stages.MessageValidator do
  @moduledoc """
  Validate parsed messages against relay-supported inbound forms.

  Supported inbound messages in this relay slice:

  - `{:event, %Nostr.Event{}}`
  - `{:event, _sub_id, %Nostr.Event{}}`
  - `{:req, sub_id, filters}` where `sub_id` is binary and `filters` is a non-empty
    list of `Nostr.Filter` structs
  - `{:count, sub_id, filters}` with the same filter constraints as `:req`
  - `{:close, sub_id}` where `sub_id` is binary
  """

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage

  @behaviour Stage

  @impl Stage
  @spec call(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, atom(), Context.t()}
  def call(%Context{parsed_message: parsed_message} = context, _options) do
    case parsed_message do
      {:event, %Event{}} ->
        {:ok, context}

      {:event, _sub_id, %Event{}} ->
        {:ok, context}

      {:req, sub_id, filters} when is_binary(sub_id) and is_list(filters) ->
        if supported_filters?(filters) do
          {:ok, context}
        else
          unsupported(context)
        end

      {:count, sub_id, filters} when is_binary(sub_id) and is_list(filters) ->
        if supported_filters?(filters) do
          {:ok, context}
        else
          unsupported(context)
        end

      {:close, sub_id} when is_binary(sub_id) ->
        {:ok, context}

      _unsupported ->
        unsupported(context)
    end
  end

  defp supported_filters?(filters) do
    filters != [] and Enum.all?(filters, &is_struct(&1, Filter))
  end

  defp unsupported(context) do
    {:error, :unsupported_message_type, Context.set_error(context, :unsupported_message_type)}
  end
end
