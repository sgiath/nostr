defmodule Nostr.Relay.Store do
  @moduledoc false

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Relay.Repo
  alias Nostr.Relay.Store.Event, as: EventRecord
  alias Nostr.Relay.Store.EventTag
  alias Nostr.Relay.Store.QueryBuilder
  alias Nostr.Tag

  @behaviour Nostr.Relay.Store.Behavior

  @impl true
  @spec insert_event(Event.t(), keyword()) :: Nostr.Relay.Store.Behavior.insert_result()
  def insert_event(%Event{} = event, opts) when is_list(opts) do
    raw_json = Keyword.get(opts, :raw_json, JSON.encode!(event))
    insert_event_with_tags(event, raw_json)
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
  @spec count_events([Filter.t()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count_events(filters, _opts) when is_list(filters) do
    QueryBuilder.count_events(filters)
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
    if Repo.get(EventRecord, event.id) do
      :duplicate
    else
      Repo.transaction(fn ->
        attrs = build_attrs(event, raw_json)

        case EventRecord.changeset(%EventRecord{}, attrs) |> Repo.insert() do
          {:ok, _record} ->
            insert_tags(event)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> normalize_transaction_result()
    end
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
