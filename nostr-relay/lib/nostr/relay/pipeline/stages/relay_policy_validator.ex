defmodule Nostr.Relay.Pipeline.Stages.RelayPolicyValidator do
  @moduledoc """
  Relay policy gate for protocol constraints.

  Current checks:

  - `min_prefix_length` — rejects REQ/COUNT filters where `ids` or `authors`
    contain prefix values shorter than the configured minimum. Full 64-character
    hex IDs are always accepted regardless of this setting.
  """

  alias Nostr.Filter
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage

  @behaviour Stage

  @impl Stage
  @spec call(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, atom(), Context.t()}
  def call(%Context{parsed_message: parsed_message} = context, _options) do
    case parsed_message do
      {:req, _sub_id, filters} when is_list(filters) ->
        validate_prefix_lengths(context, filters)

      {:count, _sub_id, filters} when is_list(filters) ->
        validate_prefix_lengths(context, filters)

      _other ->
        {:ok, context}
    end
  end

  defp validate_prefix_lengths(context, filters) do
    min_len = min_prefix_length()

    if min_len > 0 and Enum.any?(filters, &has_short_prefix?(&1, min_len)) do
      {:error, :prefix_too_short, Context.set_error(context, :prefix_too_short)}
    else
      {:ok, context}
    end
  end

  defp has_short_prefix?(%Filter{ids: ids, authors: authors}, min_len) do
    short_values?(ids, min_len) or short_values?(authors, min_len)
  end

  defp short_values?(nil, _min_len), do: false
  defp short_values?([], _min_len), do: false

  defp short_values?(values, min_len) when is_list(values) do
    Enum.any?(values, fn value ->
      len = byte_size(value)
      len < 64 and len < min_len
    end)
  end

  defp min_prefix_length do
    :nostr_relay
    |> Application.get_env(:relay_info, [])
    |> Keyword.get(:limits, %{})
    |> Map.get(:min_prefix_length, 0)
  end
end
