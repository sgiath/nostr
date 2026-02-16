defmodule Nostr.Relay.Store.GroupMember do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  schema "relay_group_memberships" do
    field :group_id, :string
    field :pubkey, :string
    field :status, :string, default: "member"
    field :last_event_id, :string
    field :last_event_created_at, :integer

    timestamps()
  end

  @type t() :: %__MODULE__{
          group_id: String.t(),
          pubkey: String.t(),
          status: String.t(),
          last_event_id: String.t() | nil,
          last_event_created_at: integer() | nil
        }

  @fields [:group_id, :pubkey, :status, :last_event_id, :last_event_created_at]

  @spec changeset(t() | Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, @fields)
    |> validate_required([:group_id, :pubkey, :status])
  end
end
