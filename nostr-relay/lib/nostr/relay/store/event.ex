defmodule Nostr.Relay.Store.Event do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:event_id, :string, autogenerate: false}

  schema "events" do
    field :pubkey, :string
    field :kind, :integer
    field :created_at, :integer
    field :content, :string, default: ""
    field :raw_json, :binary
  end

  @type t() :: %__MODULE__{
          event_id: String.t(),
          pubkey: String.t(),
          kind: non_neg_integer(),
          created_at: integer(),
          content: String.t(),
          raw_json: binary()
        }

  @fields [:event_id, :pubkey, :kind, :created_at, :content, :raw_json]

  @spec changeset(t() | Ecto.Schema.t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @fields)
    |> validate_required([:event_id, :pubkey, :kind, :created_at, :raw_json])
  end
end
