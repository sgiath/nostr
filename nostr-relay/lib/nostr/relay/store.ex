defmodule Nostr.Relay.Store do
  @moduledoc false

  import Ecto.Query

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Relay.Repo
  alias Nostr.Relay.Store.Event, as: EventRecord
  alias Nostr.Relay.Store.EventTag
  alias Nostr.Relay.Store.QueryBuilder
  alias Nostr.Tag

  @behaviour Nostr.Relay.Store.Behavior

  @impl true
  @spec insert_event(Event.t(), keyword()) :: :ok | {:error, term()}
  def insert_event(%Event{} = event, opts) when is_list(opts) do
    raw_json = Keyword.get(opts, :raw_json, JSON.encode!(event))

    case classify_kind(event.kind) do
      :ephemeral -> :ok
      :regular -> insert_regular(event, raw_json)
      :replaceable -> upsert_replaceable(event, raw_json)
      :parameterized_replaceable -> upsert_parameterized_replaceable(event, raw_json)
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  @spec query_events([Filter.t()], keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def query_events(filters, _opts) when is_list(filters) do
    case QueryBuilder.query_events(filters) do
      {:ok, records} ->
        events =
          records
          |> Enum.map(&decode_to_event/1)
          |> Enum.filter(& &1)

        {:ok, events}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  @spec event_matches_filters?(String.t(), [Filter.t()], keyword()) :: boolean()
  def event_matches_filters?(event_id, filters, _opts \\ [])
      when is_binary(event_id) and is_list(filters) do
    QueryBuilder.event_matches_filters?(event_id, filters)
  end

  @impl true
  @spec clear(keyword()) :: :ok
  def clear(_opts) do
    Repo.delete_all(EventTag)
    Repo.delete_all(EventRecord)

    :ok
  rescue
    _error -> :ok
  end

  # --- Kind classification ---

  defp classify_kind(kind) do
    cond do
      kind in [0, 3] or kind in 10_000..19_999 -> :replaceable
      kind in 20_000..29_999 -> :ephemeral
      kind in 30_000..39_999 -> :parameterized_replaceable
      true -> :regular
    end
  end

  # --- D-tag extraction ---

  defp extract_d_tag(%Event{tags: tags}) when is_list(tags) do
    case Enum.find(tags, &(&1.type == :d)) do
      %Tag{data: data} when is_binary(data) -> data
      _ -> ""
    end
  end

  # --- Regular insert (existing behavior) ---

  defp insert_regular(%Event{} = event, raw_json) do
    if Repo.get(EventRecord, event.id) do
      :ok
    else
      insert_event_with_tags(event, raw_json)
    end
  end

  # --- Replaceable upsert (kinds 0, 3, 10000-19999) ---

  defp upsert_replaceable(%Event{} = event, raw_json) do
    query =
      from(e in EventRecord,
        where: e.pubkey == ^event.pubkey and e.kind == ^event.kind
      )

    Repo.transaction(fn ->
      case Repo.one(query) do
        nil -> do_insert!(event, raw_json)
        existing -> maybe_replace!(existing, event, raw_json)
      end
    end)
    |> normalize_transaction_result()
  end

  # --- Parameterized replaceable upsert (kinds 30000-39999) ---

  defp upsert_parameterized_replaceable(%Event{} = event, raw_json) do
    d_value = extract_d_tag(event)

    query =
      from(e in EventRecord,
        join: t in EventTag,
        on: t.event_id == e.event_id,
        where:
          e.pubkey == ^event.pubkey and
            e.kind == ^event.kind and
            t.tag_name == "d" and
            t.tag_value == ^d_value
      )

    Repo.transaction(fn ->
      case Repo.one(query) do
        nil ->
          do_insert!(event, raw_json)
          maybe_ensure_d_tag(event)

        existing ->
          maybe_replace!(existing, event, raw_json)
          maybe_ensure_d_tag(event)
      end
    end)
    |> normalize_transaction_result()
  end

  # --- Compare and conditionally replace (called inside transaction) ---

  defp maybe_replace!(%EventRecord{} = existing, %Event{} = event, raw_json) do
    new_ts = DateTime.to_unix(event.created_at)

    if new_ts > existing.created_at or
         (new_ts == existing.created_at and event.id < existing.event_id) do
      replace!(existing.event_id, event, raw_json)
    else
      :skip
    end
  end

  # --- Replace: delete old + insert new (called inside transaction) ---

  defp replace!(old_event_id, %Event{} = new_event, raw_json) do
    from(t in EventTag, where: t.event_id == ^old_event_id) |> Repo.delete_all()
    Repo.delete!(%EventRecord{event_id: old_event_id})
    do_insert!(new_event, raw_json)
  end

  # --- Insert event record + tags (called inside transaction) ---

  defp do_insert!(%Event{} = event, raw_json) do
    attrs = build_attrs(event, raw_json)

    case EventRecord.changeset(%EventRecord{}, attrs) |> Repo.insert() do
      {:ok, _record} ->
        insert_tags(event)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # --- Ensure d-tag row for parameterized replaceable events ---

  defp maybe_ensure_d_tag(%Event{kind: kind} = event) when kind in 30_000..39_999 do
    d_tag_stored? =
      Enum.any?(event.tags, fn
        %Tag{type: :d, data: data} when is_binary(data) -> true
        _ -> false
      end)

    unless d_tag_stored? do
      %EventTag{}
      |> EventTag.changeset(%{event_id: event.id, tag_name: "d", tag_value: ""})
      |> Repo.insert!()
    end
  end

  defp maybe_ensure_d_tag(_event), do: :ok

  # --- Shared helpers ---

  defp build_attrs(%Event{} = event, raw_json) do
    %{
      event_id: event.id,
      pubkey: event.pubkey,
      kind: event.kind,
      created_at: DateTime.to_unix(event.created_at),
      content: event.content,
      raw_json: raw_json
    }
  end

  defp insert_event_with_tags(%Event{} = event, raw_json) do
    Repo.transaction(fn ->
      do_insert!(event, raw_json)
    end)
    |> normalize_transaction_result()
  end

  defp normalize_transaction_result({:ok, _}), do: :ok
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp insert_tags(%Event{id: event_id, tags: tags}) when is_list(tags) do
    Enum.each(tags, fn
      %Tag{type: type, data: data} when is_atom(type) and is_binary(data) ->
        tag_name = Atom.to_string(type)

        if byte_size(tag_name) == 1 and tag_name =~ ~r/^[a-zA-Z]$/ do
          %EventTag{}
          |> EventTag.changeset(%{event_id: event_id, tag_name: tag_name, tag_value: data})
          |> Repo.insert!()
        end

      _ ->
        :ok
    end)
  end

  defp insert_tags(_event), do: :ok

  defp decode_to_event(%EventRecord{event_id: event_id, raw_json: raw_json}) do
    with {:ok, decoded} <- decode_event_json(raw_json),
         {:ok, event} <- parse_event(decoded),
         {:ok, _} <- validate_event_id(event, event_id) do
      event
    else
      _ -> nil
    end
  end

  defp decode_event_json(raw_json) when is_binary(raw_json) do
    case JSON.decode(raw_json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> :error
    end
  end

  defp decode_event_json(_raw_json), do: :error

  defp parse_event(decoded) do
    case Event.parse(decoded) do
      %Event{} = event -> {:ok, event}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp validate_event_id(%Event{id: event_id}, event_id), do: {:ok, :ok}
  defp validate_event_id(_, _), do: :error
end
