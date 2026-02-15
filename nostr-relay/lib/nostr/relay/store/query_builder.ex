defmodule Nostr.Relay.Store.QueryBuilder do
  @moduledoc false

  import Ecto.Query

  alias Nostr.Filter
  alias Nostr.Relay.Repo
  alias Nostr.Relay.Store.Event, as: EventRecord

  # --- Public API ---

  @spec query_events([Filter.t()]) :: {:ok, [EventRecord.t()]}
  def query_events(filters) when is_list(filters) do
    filters = if filters == [], do: [%Filter{}], else: filters

    results =
      filters
      |> Enum.flat_map(&execute_single_filter/1)
      |> deduplicate_and_sort()
      |> apply_global_limit(filters)

    {:ok, results}
  end

  @spec event_matches_filters?(String.t(), [Filter.t()]) :: boolean()
  def event_matches_filters?(event_id, filters)
      when is_binary(event_id) and is_list(filters) do
    Enum.any?(filters, fn filter ->
      filter
      |> build_single_filter_query()
      |> where([e], e.event_id == ^event_id)
      |> limit(1)
      |> Repo.exists?()
    end)
  end

  # --- Query building ---

  @spec build_single_filter_query(Filter.t()) :: Ecto.Query.t()
  def build_single_filter_query(%Filter{} = filter) do
    EventRecord
    |> apply_ids(filter.ids)
    |> apply_authors(filter.authors)
    |> apply_kinds(filter.kinds)
    |> apply_since(filter.since)
    |> apply_until(filter.until)
    |> apply_tag_filters(filter)
    |> apply_ordering()
    |> apply_limit(filter.limit)
  end

  defp execute_single_filter(%Filter{} = filter) do
    filter
    |> build_single_filter_query()
    |> Repo.all()
  end

  # --- ids (exact + prefix matching) ---

  defp apply_ids(query, nil), do: query
  defp apply_ids(query, []), do: query

  defp apply_ids(query, ids) when is_list(ids) do
    conditions =
      Enum.reduce(ids, dynamic(false), fn id, acc ->
        if full_hex_id?(id) do
          dynamic([e], ^acc or e.event_id == ^id)
        else
          pattern = id <> "%"
          dynamic([e], ^acc or like(e.event_id, ^pattern))
        end
      end)

    where(query, ^conditions)
  end

  # --- authors (exact + prefix matching) ---

  defp apply_authors(query, nil), do: query
  defp apply_authors(query, []), do: query

  defp apply_authors(query, authors) when is_list(authors) do
    conditions =
      Enum.reduce(authors, dynamic(false), fn author, acc ->
        if full_hex_id?(author) do
          dynamic([e], ^acc or e.pubkey == ^author)
        else
          pattern = author <> "%"
          dynamic([e], ^acc or like(e.pubkey, ^pattern))
        end
      end)

    where(query, ^conditions)
  end

  # --- kinds ---

  defp apply_kinds(query, nil), do: query
  defp apply_kinds(query, []), do: query
  defp apply_kinds(query, kinds), do: where(query, [e], e.kind in ^kinds)

  # --- since / until ---

  defp apply_since(query, nil), do: query

  defp apply_since(query, %DateTime{} = since) do
    unix = DateTime.to_unix(since)
    where(query, [e], e.created_at >= ^unix)
  end

  defp apply_until(query, nil), do: query

  defp apply_until(query, %DateTime{} = until) do
    unix = DateTime.to_unix(until)
    where(query, [e], e.created_at <= ^unix)
  end

  # --- tag filters (JOIN-based) ---

  defp apply_tag_filters(query, %Filter{} = filter) do
    filter
    |> collect_tag_conditions()
    |> Enum.reduce(query, fn {tag_name, values}, q ->
      name = String.trim_leading(tag_name, "#")

      from(e in q,
        join: t in "event_tags",
        on: t.event_id == e.event_id and t.tag_name == ^name and t.tag_value in ^values
      )
    end)
  end

  defp collect_tag_conditions(%Filter{} = filter) do
    fixed =
      [{"#e", filter."#e"}, {"#p", filter."#p"}, {"#a", filter."#a"}, {"#d", filter."#d"}]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == [] end)

    dynamic =
      (filter.tags || %{})
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == [] end)
      |> Enum.to_list()

    fixed ++ dynamic
  end

  # --- ordering ---

  defp apply_ordering(query) do
    order_by(query, [e], desc: e.created_at, asc: e.event_id)
  end

  # --- limit ---

  defp apply_limit(query, nil), do: query
  defp apply_limit(query, n) when is_integer(n) and n > 0, do: limit(query, ^n)
  defp apply_limit(query, _), do: query

  # --- helpers ---

  defp deduplicate_and_sort(records) do
    records
    |> Enum.uniq_by(& &1.event_id)
    |> Enum.sort_by(&{-&1.created_at, &1.event_id})
  end

  defp apply_global_limit(records, filters) do
    case global_limit(filters) do
      nil -> records
      n when is_integer(n) and n > 0 -> Enum.take(records, n)
      _ -> records
    end
  end

  defp global_limit(filters) do
    filters
    |> Enum.map(& &1.limit)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      limits -> Enum.min(limits)
    end
  end

  defp full_hex_id?(value) when is_binary(value), do: byte_size(value) == 64
end
