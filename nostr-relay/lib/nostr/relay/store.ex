defmodule Nostr.Relay.Store do
  @moduledoc false

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Relay.Groups
  alias Nostr.Relay.Repo
  alias Nostr.Relay.Store.Event, as: EventRecord
  alias Nostr.Relay.Store.EventTag
  alias Nostr.Relay.Store.Group
  alias Nostr.Relay.Store.GroupInvite
  alias Nostr.Relay.Store.GroupMember
  alias Nostr.Relay.Store.GroupRole
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
  def query_events(filters, opts) when is_list(filters) and is_list(opts) do
    query_opts = filter_query_options(opts)

    case QueryBuilder.query_events(filters, query_opts) do
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
  def count_events(filters, opts) when is_list(filters) and is_list(opts) do
    query_opts = filter_query_options(opts)

    QueryBuilder.count_events(filters, query_opts)
  rescue
    error -> {:error, error}
  end

  @impl true
  @spec event_matches_filters?(String.t(), [Filter.t()], keyword()) :: boolean()
  def event_matches_filters?(event_id, filters, _opts \\ [])
      when is_binary(event_id) and is_list(filters) do
    QueryBuilder.event_matches_filters?(event_id, filters)
  end

  defp filter_query_options(opts) when is_list(opts) do
    []
    |> maybe_put_gift_wrap_recipients(opts)
    |> maybe_put_group_viewer_pubkeys(opts)
  end

  defp maybe_put_gift_wrap_recipients(query_opts, opts) do
    case Keyword.fetch(opts, :gift_wrap_recipients) do
      {:ok, recipients} when is_list(recipients) ->
        Keyword.put(query_opts, :gift_wrap_recipients, recipients)

      {:ok, recipient} ->
        Keyword.put(query_opts, :gift_wrap_recipients, List.wrap(recipient))

      :error ->
        query_opts
    end
  end

  defp maybe_put_group_viewer_pubkeys(query_opts, opts) do
    case Keyword.fetch(opts, :group_viewer_pubkeys) do
      {:ok, pubkeys} when is_list(pubkeys) ->
        Keyword.put(query_opts, :group_viewer_pubkeys, pubkeys)

      {:ok, pubkey} ->
        Keyword.put(query_opts, :group_viewer_pubkeys, List.wrap(pubkey))

      :error ->
        query_opts
    end
  end

  @impl true
  @spec clear(keyword()) :: :ok
  def clear(_opts) do
    Repo.delete_all(GroupInvite)
    Repo.delete_all(GroupRole)
    Repo.delete_all(GroupMember)
    Repo.delete_all(Group)
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
      run_insert_transaction(event, raw_json)
    end
  end

  defp run_insert_transaction(%Event{} = event, raw_json) do
    Repo.transaction(fn ->
      insert_record_with_tags(event, raw_json)
    end)
    |> normalize_transaction_result()
  end

  defp insert_record_with_tags(%Event{} = event, raw_json) do
    attrs = build_attrs(event, raw_json)

    case EventRecord.changeset(%EventRecord{}, attrs) |> Repo.insert() do
      {:ok, _record} ->
        insert_tags(event)
        maybe_apply_group_projection(event)

      {:error, reason} ->
        Repo.rollback(reason)
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

  defp maybe_apply_group_projection(%Event{} = event) do
    case Groups.apply_projection(event) do
      :ok ->
        :ok

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

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
