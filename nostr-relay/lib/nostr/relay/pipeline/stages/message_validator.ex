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
  - `{:auth, term()}` (NIP-42 authentication)
  """

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage

  @behaviour Stage

  @impl Stage
  @spec call(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, atom(), Context.t()}
  def call(%Context{parsed_message: parsed_message} = context, _options) do
    if supported_message?(parsed_message) do
      {:ok, context}
    else
      unsupported(context)
    end
  end

  defp supported_message?({:event, %Event{}}), do: true
  defp supported_message?({:event, _sub_id, %Event{}}), do: true

  defp supported_message?({type, sub_id, filters})
       when type in [:req, :count] and is_binary(sub_id) and is_list(filters) do
    supported_filters?(filters)
  end

  defp supported_message?({:close, sub_id}) when is_binary(sub_id), do: true
  defp supported_message?({:auth, _}), do: true
  defp supported_message?(_unsupported), do: false

  defp supported_filters?(filters) do
    filters != [] and Enum.all?(filters, &is_struct(&1, Filter))
  end

  defp unsupported(context) do
    {:error, :unsupported_message_type, Context.set_error(context, :unsupported_message_type)}
  end
end
