defmodule Nostr.Relay.Store.Group do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:group_id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "relay_groups" do
    field :managed, :boolean, default: false
    field :deleted, :boolean, default: false
    field :name, :string
    field :about, :string
    field :picture, :string
    field :private, :boolean, default: false
    field :restricted, :boolean, default: false
    field :hidden, :boolean, default: false
    field :closed, :boolean, default: false
    field :last_event_id, :string
    field :last_event_created_at, :integer

    timestamps()
  end

  @type t() :: %__MODULE__{
          group_id: String.t(),
          managed: boolean(),
          deleted: boolean(),
          name: String.t() | nil,
          about: String.t() | nil,
          picture: String.t() | nil,
          private: boolean(),
          restricted: boolean(),
          hidden: boolean(),
          closed: boolean(),
          last_event_id: String.t() | nil,
          last_event_created_at: integer() | nil
        }

  @fields [
    :group_id,
    :managed,
    :deleted,
    :name,
    :about,
    :picture,
    :private,
    :restricted,
    :hidden,
    :closed,
    :last_event_id,
    :last_event_created_at
  ]

  @spec changeset(t() | Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(group, attrs) do
    group
    |> cast(attrs, @fields)
    |> validate_required([:group_id])
  end
end
