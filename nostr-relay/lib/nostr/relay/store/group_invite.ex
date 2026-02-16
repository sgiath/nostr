defmodule Nostr.Relay.Store.GroupInvite do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  schema "relay_group_invites" do
    field :group_id, :string
    field :code, :string
    field :created_by_pubkey, :string
    field :create_event_id, :string
    field :created_at, :integer
    field :consumed_by_pubkey, :string
    field :consumed_event_id, :string
    field :consumed_at, :integer
    field :revoked_at, :integer

    timestamps()
  end

  @type t() :: %__MODULE__{
          group_id: String.t(),
          code: String.t(),
          created_by_pubkey: String.t() | nil,
          create_event_id: String.t() | nil,
          created_at: integer() | nil,
          consumed_by_pubkey: String.t() | nil,
          consumed_event_id: String.t() | nil,
          consumed_at: integer() | nil,
          revoked_at: integer() | nil
        }

  @fields [
    :group_id,
    :code,
    :created_by_pubkey,
    :create_event_id,
    :created_at,
    :consumed_by_pubkey,
    :consumed_event_id,
    :consumed_at,
    :revoked_at
  ]

  @spec changeset(t() | Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, @fields)
    |> validate_required([:group_id, :code])
  end
end
