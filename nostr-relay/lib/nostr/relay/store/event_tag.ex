defmodule Nostr.Relay.Store.EventTag do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  schema "event_tags" do
    field :event_id, :string
    field :tag_name, :string
    field :tag_value, :string
  end

  @type t() :: %__MODULE__{
          id: integer(),
          event_id: String.t(),
          tag_name: String.t(),
          tag_value: String.t()
        }

  @fields [:event_id, :tag_name, :tag_value]

  @spec changeset(t() | Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(event_tag, attrs) do
    event_tag
    # empty_values: [] preserves "" — tag values can legitimately be empty (e.g. d-tag "")
    |> cast(attrs, @fields, empty_values: [])
    |> validate_required([:event_id, :tag_name])
    |> validate_tag_value_present()
  end

  # validate_required rejects "" as blank, but Nostr tag values can be empty
  # strings (e.g. d-tag ""). This only rejects nil.
  defp validate_tag_value_present(changeset) do
    case get_field(changeset, :tag_value) do
      nil -> add_error(changeset, :tag_value, "can't be nil")
      _ -> changeset
    end
  end
end
