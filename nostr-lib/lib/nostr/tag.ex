defmodule Nostr.Tag do
  @moduledoc """
  Nostr Event tag.

  Tags are metadata attached to events. Common tag types:
  - `:e` - references another event (event ID)
  - `:p` - references a pubkey (user mention)
  - `:a` - references a parameterized replaceable event
  - `:d` - identifier for parameterized replaceable events
  - `:relay` - relay URL
  - `:challenge` - authentication challenge

  The wire format is a JSON array: `["type"]` or `["type", "data", ...additional_info]`.

  NIP-01 specifies that each tag is an array of one or more strings. Single-element
  tags (e.g. `["test"]`) are valid and represented with `data: nil`.
  """

  @enforce_keys [:type]
  defstruct type: nil, data: nil, info: []

  @type t() :: %__MODULE__{
          type: atom(),
          data: binary() | nil,
          info: [binary()]
        }

  @doc """
  Parses a JSON tag array into a `Tag` struct.

  Accepts arrays with one or more string elements per NIP-01:
  - `["type"]` → `%Tag{type: :type, data: nil, info: []}`
  - `["type", "data"]` → `%Tag{type: :type, data: "data", info: []}`
  - `["type", "data", ...info]` → `%Tag{type: :type, data: "data", info: info}`

  Returns `nil` for empty arrays.
  """
  @spec parse(tag :: list()) :: t() | nil
  def parse([]), do: nil

  def parse([type]) do
    %__MODULE__{
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      type: String.to_atom(type),
      data: nil,
      info: []
    }
  end

  def parse([type, data | info]) do
    %__MODULE__{
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      type: String.to_atom(type),
      data: data,
      info: info
    }
  end

  @doc """
  Create a type-only Nostr tag (no data or info).

  ## Example:

      iex> Nostr.Tag.create(:test)
      %Nostr.Tag{type: :test, data: nil, info: []}

  """
  @spec create(type :: atom() | binary()) :: t()
  def create(type) when is_binary(type) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    create(String.to_atom(type))
  end

  def create(type) when is_atom(type) do
    %__MODULE__{type: type}
  end

  @doc """
  Create new Nostr tag

  Each tag needs to have type and at least one data field. If tag requires more then one data
  field supply them as third argument (list of strings)

  ## Example:

      iex> Nostr.Tag.create(:e, "event-id", ["wss://relay.example.com"])
      %Nostr.Tag{type: :e, data: "event-id", info: ["wss://relay.example.com"]}

      iex> Nostr.Tag.create(:p, "pubkey")
      %Nostr.Tag{type: :p, data: "pubkey", info: []}

  """
  @spec create(type :: atom() | binary(), data :: binary(), other_data :: [binary()]) :: t()
  def create(type, data, other_data \\ [])

  def create(type, data, other_data) when is_binary(type) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    create(String.to_atom(type), data, other_data)
  end

  def create(type, data, other_data) when is_atom(type) do
    %__MODULE__{
      type: type,
      data: data,
      info: other_data
    }
  end
end

defimpl JSON.Encoder, for: Nostr.Tag do
  def encode(%Nostr.Tag{data: nil} = tag, encoder) do
    :elixir_json.encode_list([Atom.to_string(tag.type)], encoder)
  end

  def encode(%Nostr.Tag{} = tag, encoder) do
    :elixir_json.encode_list([Atom.to_string(tag.type), tag.data | tag.info], encoder)
  end
end
