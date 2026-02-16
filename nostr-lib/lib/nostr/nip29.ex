defmodule Nostr.NIP29 do
  @moduledoc """
  NIP-29: Relay-based Groups helpers.

  This module provides relay-agnostic kind classification and tag extraction helpers
  for group events.
  """
  @moduledoc tags: [:nip29], nip: 29

  alias Nostr.Event
  alias Nostr.Tag

  @join_request_kind 9_021
  @leave_request_kind 9_022
  @moderation_kind_range 9_000..9_020
  @metadata_kinds 39_000..39_003

  @type moderation_target_key :: :p | :e | :a | :code
  @type validation_error ::
          :missing_h_tag
          | :missing_d_tag
          | :invalid_group_id

  @doc "Returns true for NIP-29 moderation kinds (9000-9020)."
  @spec moderation_kind?(integer()) :: boolean()
  def moderation_kind?(kind) when is_integer(kind), do: kind in @moderation_kind_range
  def moderation_kind?(_kind), do: false

  @doc "Returns true for kind 9021 join requests."
  @spec join_request_kind?(integer()) :: boolean()
  def join_request_kind?(kind) when is_integer(kind), do: kind == @join_request_kind
  def join_request_kind?(_kind), do: false

  @doc "Returns true for kind 9022 leave requests."
  @spec leave_request_kind?(integer()) :: boolean()
  def leave_request_kind?(kind) when is_integer(kind), do: kind == @leave_request_kind
  def leave_request_kind?(_kind), do: false

  @doc "Returns true for NIP-29 relay-generated metadata kinds (39000-39003)."
  @spec metadata_kind?(integer()) :: boolean()
  def metadata_kind?(kind) when is_integer(kind), do: kind in @metadata_kinds
  def metadata_kind?(_kind), do: false

  @doc "Returns true when kind belongs to NIP-29 management path."
  @spec management_kind?(integer()) :: boolean()
  def management_kind?(kind) when is_integer(kind) do
    moderation_kind?(kind) or join_request_kind?(kind) or leave_request_kind?(kind)
  end

  def management_kind?(_kind), do: false

  @doc "Returns true when event kind requires an `h` group tag by NIP-29 semantics."
  @spec requires_h_tag?(integer()) :: boolean()
  def requires_h_tag?(kind) when is_integer(kind) do
    management_kind?(kind)
  end

  def requires_h_tag?(_kind), do: false

  @doc "Returns true when event kind requires a `d` tag (39000-39003)."
  @spec requires_d_tag?(integer()) :: boolean()
  def requires_d_tag?(kind) when is_integer(kind), do: metadata_kind?(kind)
  def requires_d_tag?(_kind), do: false

  @doc "Extracts group id from the first `h` tag on an event."
  @spec group_id_from_h(Event.t()) :: binary() | nil
  def group_id_from_h(%Event{} = event), do: get_tag_data(event, :h)

  @doc "Extracts group id from the first `d` tag on an event."
  @spec group_id_from_d(Event.t()) :: binary() | nil
  def group_id_from_d(%Event{} = event), do: get_tag_data(event, :d)

  @doc "Extracts group id using NIP-29 kind-specific tag source (`h` or `d`)."
  @spec group_id(Event.t()) :: binary() | nil
  def group_id(%Event{kind: kind} = event) do
    cond do
      requires_d_tag?(kind) -> group_id_from_d(event)
      requires_h_tag?(kind) -> group_id_from_h(event)
      true -> group_id_from_h(event) || group_id_from_d(event)
    end
  end

  @doc "Collects all `previous` references from `previous` tags preserving order."
  @spec previous_refs(Event.t()) :: [binary()]
  def previous_refs(%Event{tags: tags}) when is_list(tags) do
    Enum.flat_map(tags, fn
      %Tag{type: :previous, data: data, info: info} ->
        [data | List.wrap(info)]
        |> Enum.filter(&(is_binary(&1) and &1 != ""))

      _tag ->
        []
    end)
  end

  def previous_refs(_event), do: []

  @doc "Collects moderation target values from `p`, `e`, `a`, and `code` tags."
  @spec moderation_targets(Event.t()) :: %{moderation_target_key() => [binary()]}
  def moderation_targets(%Event{tags: tags}) when is_list(tags) do
    Enum.reduce(tags, %{p: [], e: [], a: [], code: []}, fn
      %Tag{type: type, data: data}, acc when type in [:p, :e, :a, :code] and is_binary(data) ->
        Map.update!(acc, type, &[data | &1])

      _tag, acc ->
        acc
    end)
    |> Enum.map(fn {k, values} -> {k, Enum.reverse(values)} end)
    |> Map.new()
  end

  def moderation_targets(_event), do: %{p: [], e: [], a: [], code: []}

  @doc "Validates NIP-29 group id format: lowercase alnum, `-`, `_`."
  @spec valid_group_id?(binary()) :: boolean()
  def valid_group_id?(group_id) when is_binary(group_id) do
    Regex.match?(~r/^[a-z0-9_-]+$/, group_id)
  end

  def valid_group_id?(_group_id), do: false

  @doc "Validates required `h` tag and optional group-id charset check."
  @spec validate_h_tag(Event.t(), keyword()) :: {:ok, binary()} | {:error, validation_error()}
  def validate_h_tag(%Event{} = event, opts \\ []) do
    strict_ids? = Keyword.get(opts, :strict_group_ids, false)

    with group_id when is_binary(group_id) <- group_id_from_h(event),
         :ok <- maybe_validate_group_id(group_id, strict_ids?) do
      {:ok, group_id}
    else
      nil -> {:error, :missing_h_tag}
      {:error, :invalid_group_id} -> {:error, :invalid_group_id}
    end
  end

  @doc "Validates required `d` tag and optional group-id charset check."
  @spec validate_d_tag(Event.t(), keyword()) :: {:ok, binary()} | {:error, validation_error()}
  def validate_d_tag(%Event{} = event, opts \\ []) do
    strict_ids? = Keyword.get(opts, :strict_group_ids, false)

    with group_id when is_binary(group_id) <- group_id_from_d(event),
         :ok <- maybe_validate_group_id(group_id, strict_ids?) do
      {:ok, group_id}
    else
      nil -> {:error, :missing_d_tag}
      {:error, :invalid_group_id} -> {:error, :invalid_group_id}
    end
  end

  @doc "Validates required NIP-29 structural tags for an event kind."
  @spec validate_required_group_tag(Event.t(), keyword()) ::
          {:ok, nil | binary()} | {:error, validation_error()}
  def validate_required_group_tag(%Event{kind: kind} = event, opts \\ []) do
    cond do
      requires_h_tag?(kind) ->
        validate_h_tag(event, opts)

      requires_d_tag?(kind) ->
        validate_d_tag(event, opts)

      true ->
        {:ok, group_id(event)}
    end
  end

  defp maybe_validate_group_id(_group_id, false), do: :ok

  defp maybe_validate_group_id(group_id, true) do
    if valid_group_id?(group_id), do: :ok, else: {:error, :invalid_group_id}
  end

  defp get_tag_data(%Event{tags: tags}, type) when is_list(tags) do
    case Enum.find(tags, &(&1.type == type and is_binary(&1.data))) do
      %Tag{data: data} -> data
      _ -> nil
    end
  end

  defp get_tag_data(_event, _type), do: nil
end
