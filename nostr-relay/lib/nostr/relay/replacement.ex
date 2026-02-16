defmodule Nostr.Relay.Replacement do
  @moduledoc false

  @type replacement_type :: :regular | :replaceable | :parameterized

  @doc """
  Classify an event kind for replacement semantics.

  - `:regular`: all non-replaceable kinds
  - `:replaceable`: NIP-01 metadata-like kinds and NIP-02 contact lists
  - `:parameterized`: NIP-16 parameterized replaceable kinds
  """
  @spec replacement_type(integer()) :: replacement_type
  def replacement_type(kind) when is_integer(kind) do
    cond do
      kind in [0, 3] or kind in 10_000..19_999 -> :replaceable
      kind in 30_000..39_999 -> :parameterized
      true -> :regular
    end
  end

  def replacement_type(_), do: :regular

  def replaceable?(kind), do: replacement_type(kind) == :replaceable
end
