defmodule Nostr.Relay.Store.QueryBuilder do
  @moduledoc false

  import Ecto.Query

  alias Nostr.Filter
  alias Nostr.Relay.Repo
  alias Nostr.Relay.Store.Event, as: EventRecord
  alias Nostr.Relay.Store.EventTag

  # --- Public API ---

  @spec query_events([Filter.t()]) :: {:ok, [EventRecord.t()]}
  def query_events(filters) when is_list(filters) do
    filters = if filters == [], do: [%Filter{}], else: filters

    results =
      filters
      |> Enum.flat_map(&execute_single_filter/1)
      |> deduplicate_records()
      |> apply_replacement_collapse(filters)
      |> sort_records(filters)
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

  # --- Count API ---

  @spec count_events([Filter.t()]) :: {:ok, non_neg_integer()}
  def count_events(filters) when is_list(filters) do
    filters = if filters == [], do: [%Filter{}], else: filters

    count =
      filters
      |> Enum.flat_map(&execute_single_filter/1)
      |> deduplicate_records()
      |> apply_replacement_collapse(filters)
      |> Enum.count()

    {:ok, count}
  rescue
    Exqlite.Error -> {:ok, 0}
  end

  # --- Query building ---

  @spec build_single_filter_query(Filter.t()) :: Ecto.Query.t()
  def build_single_filter_query(%Filter{} = filter) do
    filter
    |> build_filter_base_query()
    |> apply_ordering(filter.search)
    |> apply_limit(filter.limit)
  end

  # --- Query building (internal) ---

  defp build_filter_base_query(%Filter{} = filter) do
    EventRecord
    |> apply_ephemeral_filter()
    |> apply_ids(filter.ids)
    |> apply_authors(filter.authors)
    |> apply_kinds(filter.kinds)
    |> apply_since(filter.since)
    |> apply_until(filter.until)
    |> apply_tag_filters(filter)
    |> apply_search(filter.search)
  end

  defp execute_single_filter(%Filter{} = filter) do
    filter
    |> build_single_filter_query()
    |> Repo.all()
  rescue
    # FTS5 MATCH errors from malformed search queries
    Exqlite.Error -> []
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

  # --- search (NIP-50 FTS5) ---

  defp apply_search(query, nil), do: query
  defp apply_search(query, ""), do: query

  defp apply_search(query, search) when is_binary(search) do
    sanitized = sanitize_fts_query(search)

    if sanitized == "" do
      query
    else
      where(
        query,
        [e],
        fragment(
          "?.rowid IN (SELECT rowid FROM events_fts WHERE events_fts MATCH ?)",
          e,
          ^sanitized
        )
      )
    end
  end

  # --- ordering ---

  # Search results: sort by FTS5 rank (lower = more relevant)
  defp apply_ordering(query, search) when is_binary(search) and search != "" do
    order_by(query, [e],
      asc: fragment("(SELECT rank FROM events_fts WHERE events_fts.rowid = ?.rowid)", e)
    )
  end

  defp apply_ordering(query, _search) do
    order_by(query, [e], desc: e.created_at, asc: e.event_id)
  end

  # --- limit ---

  defp apply_limit(query, nil), do: query
  defp apply_limit(query, n) when is_integer(n) and n >= 0, do: limit(query, ^n)
  defp apply_limit(query, _), do: query

  # --- helpers ---

  defp apply_replacement_collapse(records, filters) do
    if ids_only_filters?(filters) do
      records
    else
      d_tags = fetch_parameterized_d_tags(records)

      records
      |> Enum.reduce(%{}, fn record, groups ->
        key = replacement_group_key(record, d_tags)

        case Map.get(groups, key) do
          nil ->
            Map.put(groups, key, record)

          existing_record ->
            if newer_event?(record, existing_record),
              do: Map.put(groups, key, record),
              else: groups
        end
      end)
      |> Map.values()
    end
  end

  defp replacement_group_key(%EventRecord{} = record, d_tags) do
    case replacement_kind(record.kind) do
      :replaceable ->
        {:replaceable, record.pubkey, record.kind}

      :parameterized ->
        {:parameterized, record.pubkey, record.kind, Map.get(d_tags, record.event_id, "")}

      :regular ->
        {:regular, record.event_id}
    end
  end

  defp replacement_kind(kind) when kind in [0, 3] or kind in 10_000..19_999, do: :replaceable

  defp replacement_kind(kind) when kind in 30_000..39_999, do: :parameterized

  defp replacement_kind(_kind), do: :regular

  defp newer_event?(%EventRecord{} = candidate, %EventRecord{} = existing) do
    candidate.created_at > existing.created_at or
      (candidate.created_at == existing.created_at and candidate.event_id < existing.event_id)
  end

  defp fetch_parameterized_d_tags(records) do
    records
    |> Enum.filter(&parameterized_replaceable_kind?/1)
    |> Enum.map(& &1.event_id)
    |> Enum.uniq()
    |> fetch_d_tags()
  end

  defp fetch_d_tags([]), do: %{}

  defp fetch_d_tags(event_ids) when is_list(event_ids) do
    from(t in EventTag,
      where: t.event_id in ^event_ids and t.tag_name == "d",
      select: {t.event_id, t.tag_value}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {event_id, tag_value}, acc ->
      Map.put_new(acc, event_id, tag_value)
    end)
  end

  defp parameterized_replaceable_kind?(%EventRecord{kind: kind}) when kind in 30_000..39_999,
    do: true

  defp parameterized_replaceable_kind?(_record), do: false

  defp ids_only_filters?(filters) do
    Enum.all?(filters, &ids_only_filter?/1)
  end

  defp ids_only_filter?(%Filter{} = filter) do
    filter.ids not in [nil, []] and
      filter.authors in [nil, []] and
      filter.kinds in [nil, []] and
      filter."#e" in [nil, []] and
      filter."#p" in [nil, []] and
      filter."#a" in [nil, []] and
      filter."#d" in [nil, []] and
      filter.since == nil and
      filter.until == nil and
      filter.search in [nil, ""] and
      tags_empty?(filter.tags)
  end

  defp tags_empty?(nil), do: true
  defp tags_empty?(tags), do: tags == %{}

  defp deduplicate_records(records) do
    Enum.uniq_by(records, & &1.event_id)
  end

  # When all filters are search queries, preserve SQL relevance ordering.
  # Otherwise use created_at DESC then event_id ASC.
  defp sort_records(records, filters) do
    if all_search_filters?(filters) do
      records
    else
      Enum.sort_by(records, &{-&1.created_at, &1.event_id})
    end
  end

  defp all_search_filters?(filters) do
    Enum.all?(filters, fn f -> is_binary(f.search) and f.search != "" end)
  end

  defp apply_global_limit(records, filters) do
    case global_limit(filters) do
      nil -> records
      n when is_integer(n) and n >= 0 -> Enum.take(records, n)
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

  # --- FTS5 query sanitization ---

  # Splits search into tokens, strips NIP-50 extension tokens (key:value),
  # and wraps each token in double quotes to escape FTS5 special syntax.
  defp sanitize_fts_query(search) when is_binary(search) do
    search
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&extension_token?/1)
    |> Enum.map_join(" ", &quote_fts_token/1)
  end

  # NIP-50 extensions use key:value syntax (e.g. language:en, domain:example.com)
  defp extension_token?(token), do: Regex.match?(~r/^[a-z]+:/, token)

  # Wrap token in double quotes, escaping any internal double quotes
  defp quote_fts_token(token) do
    escaped = String.replace(token, "\"", "\"\"")
    "\"#{escaped}\""
  end

  defp apply_ephemeral_filter(query) do
    where(query, [e], e.kind < 20_000 or e.kind > 29_999)
  end
end
