defmodule Nostr.Filter do
  @moduledoc """
  Nostr filter
  """

  alias Nostr.Event
  alias Nostr.Tag

  defstruct [
    :ids,
    :authors,
    :kinds,
    :"#e",
    :"#p",
    :"#a",
    :"#d",
    :since,
    :until,
    :limit,
    :search,
    :tags
  ]

  @type t() :: %__MODULE__{
          ids: nil | [<<_::32, _::_*8>>],
          authors: nil | [<<_::32, _::_*8>>],
          kinds: nil | [non_neg_integer()],
          "#e": nil | [<<_::32, _::_*8>>],
          "#p": nil | [<<_::32, _::_*8>>],
          # award definition link
          "#a": nil | [<<_::32, _::_*8>>],
          # badge name
          "#d": nil | [binary()],
          since: nil | DateTime.t(),
          until: nil | DateTime.t(),
          limit: nil | non_neg_integer(),
          search: nil | String.t(),
          # Arbitrary single-letter tag filters (NIP-01)
          tags: nil | %{String.t() => [binary()]}
        }

  # Known keys that map to struct fields
  @known_keys %{
    "ids" => :ids,
    "authors" => :authors,
    "kinds" => :kinds,
    "#e" => :"#e",
    "#p" => :"#p",
    "#a" => :"#a",
    "#d" => :"#d",
    "since" => :since,
    "until" => :until,
    "limit" => :limit,
    "search" => :search
  }

  # Single-letter tag pattern (NIP-01: #<single-letter (a-zA-Z)>)
  @tag_pattern ~r/^#[a-zA-Z]$/

  @doc """
  Parse filter from raw list to `Nostr.Filter` struct
  """
  @spec parse(map) :: __MODULE__.t()
  def parse(filter) when is_map(filter) do
    {known, extra_tags} = Enum.reduce(filter, {%{}, %{}}, &classify_key/2)

    known
    |> maybe_add_tags(extra_tags)
    |> maybe_parse_timestamp(:since)
    |> maybe_parse_timestamp(:until)
    |> then(&struct(__MODULE__, &1))
  end

  @doc """
  Returns `true` if the event matches any filter in the list (OR semantics).
  """
  @spec any_match?([t()], Event.t()) :: boolean()
  def any_match?(filters, %Event{} = event) when is_list(filters) do
    Enum.any?(filters, &matches?(&1, event))
  end

  @doc """
  Returns `true` if the event satisfies all present constraints in the filter
  (AND semantics). A `nil` field means no constraint — always passes.
  """
  @spec matches?(t(), Event.t()) :: boolean()
  def matches?(%__MODULE__{} = filter, %Event{} = event) do
    matches_ids?(event, filter.ids) and
      matches_authors?(event, filter.authors) and
      matches_kinds?(event, filter.kinds) and
      matches_since?(event, filter.since) and
      matches_until?(event, filter.until) and
      matches_tags?(event, filter) and
      matches_search?(event, filter.search)
  end

  # --- Matching helpers (NIP-01 semantics) ---

  # All tag constraints in one pass to keep matches?/2 cyclomatic complexity low
  defp matches_tags?(event, filter) do
    matches_tag_field?(event, :e, filter."#e") and
      matches_tag_field?(event, :p, filter."#p") and
      matches_tag_field?(event, :a, filter."#a") and
      matches_tag_field?(event, :d, filter."#d") and
      matches_dynamic_tags?(event, filter.tags)
  end

  # ids: prefix match — event.id must start with any prefix in the list
  defp matches_ids?(_event, nil), do: true

  defp matches_ids?(%Event{id: id}, ids) when is_list(ids) do
    Enum.any?(ids, &String.starts_with?(id, &1))
  end

  # authors: prefix match — event.pubkey must start with any prefix in the list
  defp matches_authors?(_event, nil), do: true

  defp matches_authors?(%Event{pubkey: pubkey}, authors) when is_list(authors) do
    Enum.any?(authors, &String.starts_with?(pubkey, &1))
  end

  # kinds: membership — event.kind must be in the list
  defp matches_kinds?(_event, nil), do: true

  defp matches_kinds?(%Event{kind: kind}, kinds) when is_list(kinds) do
    kind in kinds
  end

  # since: event.created_at >= since
  defp matches_since?(_event, nil), do: true

  defp matches_since?(%Event{created_at: created_at}, since) do
    DateTime.compare(created_at, since) in [:gt, :eq]
  end

  # until: event.created_at <= until
  defp matches_until?(_event, nil), do: true

  defp matches_until?(%Event{created_at: created_at}, until) do
    DateTime.compare(created_at, until) in [:lt, :eq]
  end

  # Named tag fields (#e, #p, #a, #d): event must have a tag of that type
  # with data matching any value in the list
  defp matches_tag_field?(_event, _tag_type, nil), do: true

  defp matches_tag_field?(%Event{tags: tags}, tag_type, values) when is_list(values) do
    Enum.any?(tags, fn
      %Tag{type: ^tag_type, data: data} -> data in values
      _ -> false
    end)
  end

  # Dynamic tags map (e.g. %{"#t" => ["nostr"]}): each entry must match at least
  # one tag on the event. All entries must match (AND).
  defp matches_dynamic_tags?(_event, nil), do: true
  defp matches_dynamic_tags?(_event, tags) when map_size(tags) == 0, do: true

  defp matches_dynamic_tags?(%Event{tags: event_tags}, tag_filters) when is_map(tag_filters) do
    Enum.all?(tag_filters, fn {"#" <> letter, values} ->
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      tag_atom = String.to_atom(letter)

      Enum.any?(event_tags, fn
        %Tag{type: ^tag_atom, data: data} -> data in values
        _ -> false
      end)
    end)
  end

  # search: case-insensitive substring match on event.content (NIP-50)
  defp matches_search?(_event, nil), do: true
  defp matches_search?(_event, ""), do: true

  defp matches_search?(%Event{content: content}, search) when is_binary(search) do
    downcased = String.downcase(content || "")

    search
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&search_extension?/1)
    |> case do
      [] -> true
      terms -> Enum.all?(terms, &String.contains?(downcased, String.downcase(&1)))
    end
  end

  # NIP-50 extensions use key:value syntax (e.g. language:en)
  defp search_extension?(token), do: String.contains?(token, ":")

  defp classify_key({key, value}, {known_acc, tags_acc}) do
    str_key = if is_atom(key), do: Atom.to_string(key), else: key

    case Map.fetch(@known_keys, str_key) do
      {:ok, atom_key} ->
        {Map.put(known_acc, atom_key, value), tags_acc}

      :error ->
        if Regex.match?(@tag_pattern, str_key) do
          {known_acc, Map.put(tags_acc, str_key, value)}
        else
          {known_acc, tags_acc}
        end
    end
  end

  defp maybe_add_tags(known, extra_tags) when map_size(extra_tags) > 0 do
    Map.put(known, :tags, extra_tags)
  end

  defp maybe_add_tags(known, _extra_tags), do: known

  defp maybe_parse_timestamp(known, field) do
    case Map.fetch(known, field) do
      {:ok, value} when is_integer(value) ->
        safe_put_timestamp(known, field, value)

      {:ok, value} when is_float(value) ->
        value
        |> trunc()
        |> then(&safe_put_timestamp(known, field, &1))

      _not_found ->
        known
    end
  end

  defp safe_put_timestamp(known, field, unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> Map.put(known, field, dt)
      {:error, _} -> Map.delete(known, field)
    end
  end
end

defimpl JSON.Encoder, for: Nostr.Filter do
  def encode(%Nostr.Filter{} = filter, encoder) do
    # Extract extra tags before converting
    extra_tags = filter.tags || %{}

    filter
    |> Map.update!(:since, &encode_unix/1)
    |> Map.update!(:until, &encode_unix/1)
    |> Map.from_struct()
    |> Map.delete(:tags)
    |> Enum.reject(fn {_key, val} -> is_nil(val) end)
    |> Enum.into(%{})
    |> Map.merge(extra_tags)
    |> :elixir_json.encode_map(encoder)
  end

  defp encode_unix(nil), do: nil
  defp encode_unix(date_time), do: DateTime.to_unix(date_time)
end
