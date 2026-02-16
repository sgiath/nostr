defmodule Nostr.Relay.Store.QueryBuilder do
  @moduledoc false

  import Ecto.Query

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Relay.Groups.Visibility, as: GroupVisibility
  alias Nostr.Relay.Repo
  alias Nostr.Relay.Store.Event, as: EventRecord
  alias Nostr.Relay.Store.EventTag
  alias Nostr.Relay.Replacement
  alias Nostr.Tag

  # --- Public API ---

  @spec query_events([Filter.t()], keyword()) :: {:ok, [EventRecord.t()]}
  def query_events(filters, opts \\ []) when is_list(filters) and is_list(opts) do
    filters = if filters == [], do: [%Filter{}], else: filters

    results =
      filters
      |> Enum.flat_map(&execute_single_filter/1)
      |> deduplicate_records()
      |> apply_gift_wrap_recipient_filter(opts)
      |> apply_group_visibility_filter(opts)
      |> apply_expiration_filter()
      |> apply_replacement_collapse(filters)
      |> apply_deletion_filter()
      |> sort_records(filters)
      |> apply_global_limit(filters)

    {:ok, results}
  end

  @spec event_deleted?(Event.t()) :: boolean()
  def event_deleted?(%Event{kind: 5}), do: false

  def event_deleted?(%Event{
        created_at: %DateTime{} = created_at,
        id: event_id,
        pubkey: event_pubkey,
        kind: kind,
        tags: tags
      })
      when is_binary(event_id) and is_binary(event_pubkey) and is_integer(kind) and is_list(tags) do
    candidate =
      %EventRecord{
        event_id: event_id,
        pubkey: event_pubkey,
        kind: kind,
        created_at: DateTime.to_unix(created_at)
      }

    deletion_data = deletion_scope([event_pubkey])
    record_d_tags = %{event_id => event_d_tag(tags)}

    event_is_hidden?(candidate, deletion_data, record_d_tags)
  end

  def event_deleted?(_event), do: false

  @spec event_matches_filters?(String.t(), [Filter.t()]) :: boolean()
  def event_matches_filters?(event_id, filters)
      when is_binary(event_id) and is_list(filters) do
    Enum.any?(filters, fn filter ->
      record =
        filter
        |> build_single_filter_query()
        |> where([e], e.event_id == ^event_id)
        |> limit(1)
        |> Repo.one()

      case record do
        nil ->
          false

        _record ->
          record = apply_expiration_filter([record])
          apply_deletion_filter(record) != []
      end
    end)
  end

  # --- Count API ---

  @spec count_events([Filter.t()], keyword()) :: {:ok, non_neg_integer()}
  def count_events(filters, opts \\ []) when is_list(filters) and is_list(opts) do
    filters = if filters == [], do: [%Filter{}], else: filters

    count =
      filters
      |> Enum.flat_map(&execute_single_filter/1)
      |> deduplicate_records()
      |> apply_gift_wrap_recipient_filter(opts)
      |> apply_group_visibility_filter(opts)
      |> apply_expiration_filter()
      |> apply_replacement_collapse(filters)
      |> apply_deletion_filter()
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

  # --- deletion visibility (NIP-09 read-path suppression) ---

  defp apply_deletion_filter(records) when is_list(records) do
    visible_records =
      records
      |> Enum.reject(&deletion_event?/1)
      |> apply_deletion_filter_to_records(records)

    visible_records
  end

  # --- expiration (NIP-40) ---

  defp apply_expiration_filter(records) when records == [] do
    records
  end

  defp apply_expiration_filter(records) when is_list(records) do
    now = DateTime.to_unix(DateTime.utc_now())
    expired_ids = expired_event_ids(records, now)

    Enum.reject(records, fn record ->
      MapSet.member?(expired_ids, record.event_id)
    end)
  end

  defp expired_event_ids(_records, now) when not is_integer(now) do
    MapSet.new()
  end

  defp expired_event_ids(records, now) when is_list(records) and is_integer(now) do
    Enum.reduce(records, MapSet.new(), fn record, expired_ids ->
      case record_expired?(record, now) do
        true -> MapSet.put(expired_ids, record.event_id)
        false -> expired_ids
      end
    end)
  end

  defp record_expired?(%EventRecord{raw_json: raw_json}, now) when is_binary(raw_json) do
    case JSON.decode(raw_json) do
      {:ok, %{"tags" => tags}} when is_list(tags) ->
        Enum.any?(tags, fn
          ["expiration", value | _] -> expired_expiration_tag?(value, now)
          ["expiration" | _] -> false
          _ -> false
        end)

      _ ->
        false
    end
  end

  defp record_expired?(_record, _now), do: false

  defp expired_expiration_tag?(value, now) do
    case parse_expiration_timestamp(value) do
      {:ok, timestamp} -> timestamp <= now
      _ -> false
    end
  end

  defp parse_expiration_timestamp(value) when is_integer(value) do
    {:ok, value}
  end

  defp parse_expiration_timestamp(value) when is_float(value) do
    if Float.floor(value) == value do
      {:ok, trunc(value)}
    else
      :error
    end
  end

  defp parse_expiration_timestamp(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {timestamp, ""} -> {:ok, timestamp}
      _ -> :error
    end
  end

  defp parse_expiration_timestamp(_value), do: :error

  defp apply_deletion_filter_to_records(records, all_records) do
    if records == [] do
      all_records
    else
      data = deletion_scope(fetch_relevant_pubkeys(records))
      candidate_d_tags = fetch_record_d_tags(records)

      Enum.filter(all_records, fn record ->
        !event_is_hidden?(record, data, candidate_d_tags)
      end)
    end
  end

  defp deletion_event?(%EventRecord{kind: 5}), do: true
  defp deletion_event?(_event), do: false

  defp fetch_relevant_pubkeys(records) do
    records
    |> Enum.map(& &1.pubkey)
    |> Enum.uniq()
  end

  defp deletion_scope(pubkeys) when pubkeys == [] do
    empty_deletion_scope()
  end

  defp deletion_scope(pubkeys) do
    now = DateTime.to_unix(DateTime.utc_now())

    pubkeys
    |> deletion_events_for_pubkeys()
    |> Enum.reject(&record_expired?(&1, now))
    |> build_deletion_scope()
  end

  defp empty_deletion_scope do
    %{event_id_rules: %{}, address_rules: %{}}
  end

  defp build_deletion_scope([]), do: empty_deletion_scope()

  defp build_deletion_scope(deletion_event_records) do
    tags_by_deletion =
      deletion_event_records
      |> Enum.map(& &1.event_id)
      |> fetch_deletion_tag_index()

    Enum.reduce(deletion_event_records, empty_deletion_scope(), fn
      %EventRecord{
        event_id: deletion_id,
        pubkey: deletion_pubkey,
        created_at: deletion_created_at
      },
      scope ->
        tags = Map.get(tags_by_deletion, deletion_id, %{})
        kind_filter = parse_kind_filter(Map.get(tags, "k", []))

        scope
        |> add_event_id_deletions(deletion_pubkey, Map.get(tags, "e", []), kind_filter)
        |> add_address_deletions(
          deletion_pubkey,
          Map.get(tags, "a", []),
          kind_filter,
          deletion_created_at
        )
    end)
  end

  defp deletion_events_for_pubkeys(pubkeys) do
    from(d in EventRecord, where: d.kind == 5 and d.pubkey in ^pubkeys)
    |> Repo.all()
  end

  defp fetch_deletion_tag_index(deletion_event_ids) when deletion_event_ids == [] do
    %{}
  end

  defp fetch_deletion_tag_index(deletion_event_ids) do
    from(t in EventTag,
      where: t.event_id in ^deletion_event_ids,
      select: {t.event_id, t.tag_name, t.tag_value}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {event_id, tag_name, tag_value}, grouped ->
      by_event = Map.get(grouped, event_id, %{})
      values = Map.get(by_event, tag_name, [])

      Map.put(grouped, event_id, Map.put(by_event, tag_name, [tag_value | values]))
    end)
  end

  defp add_event_id_deletions(scope, _publisher, tag_values, _kind_filter)
       when tag_values == [] do
    scope
  end

  defp add_event_id_deletions(scope, publisher, tag_values, kind_filter)
       when is_list(tag_values) do
    Enum.reduce(tag_values, scope, fn
      event_id, acc when is_binary(event_id) and byte_size(event_id) == 64 ->
        existing = Map.get(acc.event_id_rules, {publisher, event_id}, [])
        updated = Map.put(acc.event_id_rules, {publisher, event_id}, [kind_filter | existing])

        %{acc | event_id_rules: updated}

      _value, acc ->
        acc
    end)
  end

  defp add_event_id_deletions(scope, _publisher, _tag_values, _kind_filter) do
    scope
  end

  defp add_address_deletions(scope, _publisher, tag_values, _kind_filter, _deletion_created_at)
       when tag_values == [] do
    scope
  end

  defp add_address_deletions(
         scope,
         deletion_pubkey,
         tag_values,
         kind_filter,
         deletion_created_at
       )
       when is_list(tag_values) do
    Enum.reduce(tag_values, scope, fn value, acc ->
      case parse_address_coord(value, deletion_pubkey) do
        {:ok, coordinate} ->
          key = coordinate
          existing = Map.get(acc.address_rules, key, [])

          updated =
            Map.put(acc.address_rules, key, [{deletion_created_at, kind_filter} | existing])

          %{acc | address_rules: updated}

        _ ->
          acc
      end
    end)
  end

  defp add_address_deletions(scope, _publisher, _tag_values, _kind_filter, _deletion_created_at) do
    scope
  end

  # Coordinate format: kind:pubkey:d-tag
  defp parse_address_coord(value, deletion_pubkey) when is_binary(value) do
    with [kind_value, pubkey, d_tag] <- String.split(value, ":", parts: 3),
         kind when is_integer(kind) <- parse_kind_integer(kind_value),
         true <- pubkey == deletion_pubkey do
      {:ok, {deletion_pubkey, kind, d_tag}}
    else
      _ -> {:ignore, :invalid}
    end
  end

  defp parse_address_coord(_value, _deletion_pubkey), do: {:ignore, :invalid}

  defp parse_kind_filter(values) when is_list(values) do
    parsed_kinds =
      values
      |> Enum.map(&parse_kind_integer/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if parsed_kinds == [] do
      nil
    else
      MapSet.new(parsed_kinds)
    end
  end

  defp parse_kind_filter(_values), do: nil

  defp parse_kind_integer(value) when is_integer(value) and value >= 0 do
    value
  end

  defp parse_kind_integer(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {kind, ""} when kind >= 0 -> kind
      _ -> nil
    end
  end

  defp parse_kind_integer(_value), do: nil

  defp event_is_hidden?(%EventRecord{} = event, deletion_scope, record_d_tags) do
    case event.kind do
      5 ->
        false

      _ ->
        event_id_rules =
          Map.get(deletion_scope.event_id_rules, {event.pubkey, event.event_id}, [])

        address_d_tag = Map.get(record_d_tags, event.event_id, "")

        address_rules =
          Map.get(deletion_scope.address_rules, {event.pubkey, event.kind, address_d_tag}, [])

        deleted_by_event_id?(event.kind, event_id_rules) ||
          deleted_by_address?(event.created_at, event.kind, address_rules)
    end
  end

  defp deleted_by_event_id?(kind, kind_rules) do
    Enum.any?(kind_rules, &kind_filter_allows?(&1, kind))
  end

  defp deleted_by_address?(created_at, event_kind, address_rules) do
    Enum.any?(address_rules, fn {deletion_created_at, kind_rules} ->
      created_at <= deletion_created_at and kind_filter_allows?(kind_rules, event_kind)
    end)
  end

  defp event_d_tag(tags) when is_list(tags) do
    tags
    |> Enum.find_value(fn
      %Tag{type: :d, data: data} when is_binary(data) -> data
      _ -> nil
    end)
    |> Kernel.||("")
  end

  defp event_d_tag(_tags), do: ""

  defp kind_filter_allows?(nil, _kind), do: true
  defp kind_filter_allows?(kind_set, kind), do: kind in kind_set

  defp fetch_record_d_tags(records) do
    records
    |> Enum.map(& &1.event_id)
    |> fetch_d_tags()
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
    if ids_only_filters?(filters) and not kind_41_records?(records) do
      records
    else
      d_tags = fetch_parameterized_d_tags(records)

      records
      |> Enum.reduce(%{}, fn record, groups ->
        key = replacement_group_key(record, d_tags)
        Map.update(groups, key, record, &newest_record(record, &1))
      end)
      |> Map.values()
    end
  end

  defp newest_record(record, existing_record) do
    if newer_event?(record, existing_record), do: record, else: existing_record
  end

  defp kind_41_records?(records) when is_list(records) do
    Enum.any?(records, &(&1.kind == 41))
  end

  defp replacement_group_key(%EventRecord{} = record, d_tags) do
    kind_41_group_key(record) ||
      case replacement_kind(record.kind) do
        :replaceable ->
          {:replaceable, record.pubkey, record.kind}

        :parameterized ->
          {:parameterized, record.pubkey, record.kind, Map.get(d_tags, record.event_id, "")}

        :regular ->
          {:regular, record.event_id}
      end
  end

  defp kind_41_group_key(%EventRecord{kind: 41} = record) do
    case extract_kind_41_root_e_tag(record) do
      root_id when is_binary(root_id) -> {:channel_metadata_root, root_id}
      _ -> nil
    end
  end

  defp kind_41_group_key(_record), do: nil

  defp extract_kind_41_root_e_tag(%EventRecord{raw_json: raw_json}) when is_binary(raw_json) do
    tags = decode_event_tags(raw_json)

    root_marked_e_tag(tags) || first_e_tag(tags)
  end

  defp extract_kind_41_root_e_tag(_record), do: nil

  defp decode_event_tags(raw_json) when is_binary(raw_json) do
    case JSON.decode(raw_json) do
      {:ok, %{"tags" => tags}} when is_list(tags) -> tags
      _ -> []
    end
  end

  defp root_marked_e_tag(tags) when is_list(tags) do
    Enum.find_value(tags, fn
      ["e", event_id, _relay, "root" | _rest] ->
        if valid_kind_41_root_id?(event_id), do: event_id

      ["e", event_id, "root" | _rest] ->
        if valid_kind_41_root_id?(event_id), do: event_id

      _ ->
        nil
    end)
  end

  defp first_e_tag(tags) when is_list(tags) do
    Enum.find_value(tags, fn
      ["e", event_id | _rest] ->
        if valid_kind_41_root_id?(event_id), do: event_id

      _ ->
        nil
    end)
  end

  defp valid_kind_41_root_id?(event_id) do
    is_binary(event_id) and event_id != ""
  end

  defp replacement_kind(kind), do: Replacement.replacement_type(kind)

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

  defp parameterized_replaceable_kind?(%EventRecord{kind: kind}) do
    Replacement.replacement_type(kind) == :parameterized
  end

  defp ids_only_filters?(filters) do
    Enum.all?(filters, &ids_only_filter?/1)
  end

  defp ids_only_filter?(%Filter{} = filter) do
    tag_filters = [filter."#e", filter."#p", filter."#a", filter."#d"]

    populated_ids?(filter.ids) and
      blank_list?(filter.authors) and
      blank_list?(filter.kinds) and
      Enum.all?(tag_filters, &blank_list?/1) and
      is_nil(filter.since) and
      is_nil(filter.until) and
      blank_search?(filter.search) and
      tags_empty?(filter.tags)
  end

  defp populated_ids?(ids), do: not blank_list?(ids)

  defp blank_list?(value), do: value in [nil, []]

  defp blank_search?(value), do: value in [nil, ""]

  defp tags_empty?(nil), do: true
  defp tags_empty?(tags), do: tags == %{}

  defp deduplicate_records(records) do
    Enum.uniq_by(records, & &1.event_id)
  end

  # --- Private message read filtering ------------------------------------------

  defp apply_gift_wrap_recipient_filter(records, opts) when is_list(records) do
    case gift_wrap_recipients(opts) do
      :no_filter ->
        records

      :exclude_all ->
        Enum.reject(records, &private_message_kind?(&1.kind))

      recipients when is_list(recipients) ->
        {wrapped, others} = Enum.split_with(records, &private_message_kind?(&1.kind))

        if wrapped == [] do
          records
        else
          allowed_ids = visible_gift_wrap_event_ids(wrapped, recipients)

          others ++ Enum.filter(wrapped, &MapSet.member?(allowed_ids, &1.event_id))
        end
    end
  end

  defp gift_wrap_recipients(opts) when is_list(opts) do
    case Keyword.fetch(opts, :gift_wrap_recipients) do
      {:ok, []} ->
        :exclude_all

      {:ok, nil} ->
        :exclude_all

      {:ok, recipients} when is_binary(recipients) ->
        [recipients]

      {:ok, recipients} when is_list(recipients) ->
        recipients = Enum.uniq(recipients)

        if recipients == [] do
          :exclude_all
        else
          recipients
        end

      {:ok, _} ->
        :exclude_all

      :error ->
        :no_filter
    end
  end

  defp visible_gift_wrap_event_ids(wrapped_records, recipients) when is_list(wrapped_records) do
    wrapped_ids =
      wrapped_records
      |> Enum.map(& &1.event_id)

    if wrapped_ids == [] do
      MapSet.new()
    else
      from(t in EventTag,
        where:
          t.event_id in ^wrapped_ids and
            t.tag_name == "p" and
            t.tag_value in ^recipients,
        select: t.event_id
      )
      |> Repo.all()
      |> MapSet.new()
    end
  end

  defp private_message_kind?(kind), do: kind in [4, 10_59]

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

  # --- NIP-29 group visibility ---

  defp apply_group_visibility_filter(records, opts) when is_list(records) and is_list(opts) do
    case Keyword.fetch(opts, :group_viewer_pubkeys) do
      {:ok, viewer_pubkeys} when is_list(viewer_pubkeys) ->
        Enum.filter(records, &group_record_visible?(&1, viewer_pubkeys))

      {:ok, viewer_pubkey} when is_binary(viewer_pubkey) ->
        apply_group_visibility_filter(records, group_viewer_pubkeys: [viewer_pubkey])

      _ ->
        records
    end
  end

  defp apply_group_visibility_filter(records, _opts), do: records

  defp group_record_visible?(record, viewer_pubkeys) do
    case decode_record_event(record) do
      %Event{} = event ->
        GroupVisibility.visible?(
          event,
          viewer_pubkeys,
          Application.get_env(:nostr_relay, :nip29, [])
        )

      _ ->
        false
    end
  end

  defp decode_record_event(%EventRecord{raw_json: raw_json}) when is_binary(raw_json) do
    case JSON.decode(raw_json) do
      {:ok, map} ->
        case Event.parse(map) do
          %Event{} = event -> event
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp decode_record_event(_record), do: nil

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
