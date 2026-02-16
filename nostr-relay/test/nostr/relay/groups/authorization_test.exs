defmodule Nostr.Relay.Groups.AuthorizationTest do
  use Nostr.Relay.DataCase, async: false

  alias Nostr.Event
  alias Nostr.Tag
  alias Nostr.Relay.Groups.Authorization
  alias Nostr.Relay.Store.Group
  alias Nostr.Relay.Store.GroupMember

  @seckey_a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @seckey_b "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  setup do
    original_info = Application.get_env(:nostr_relay, :relay_info)
    original_identity = Application.get_env(:nostr_relay, :relay_identity)

    on_exit(fn ->
      Application.put_env(:nostr_relay, :relay_info, original_info)
      Application.put_env(:nostr_relay, :relay_identity, original_identity)
    end)

    :ok
  end

  test "rejects metadata events signed by non-relay pubkey" do
    relay_pubkey =
      Event.create(1)
      |> Event.sign(@seckey_a)
      |> Map.fetch!(:pubkey)

    Application.put_env(:nostr_relay, :relay_identity, self_pub: relay_pubkey)

    event =
      Event.create(39_000, tags: [Tag.create(:d, "group_1")])
      |> Event.sign(@seckey_b)

    assert {:error, "restricted: metadata events must be signed by relay pubkey"} =
             Authorization.authorize_event(event, [], enabled: true)
  end

  test "rejects writes to restricted groups by non-members" do
    event =
      Event.create(1, tags: [Tag.create(:h, "group_1")])
      |> Event.sign(@seckey_a)

    group_attrs = %{group_id: "group_1", restricted: true, managed: true}

    %Group{}
    |> Group.changeset(group_attrs)
    |> Repo.insert!()

    assert {:error, "restricted: group write requires membership"} =
             Authorization.authorize_event(event, [], enabled: true)
  end

  test "allows writes to restricted groups for members" do
    event =
      Event.create(1, tags: [Tag.create(:h, "group_1")])
      |> Event.sign(@seckey_a)

    group_attrs = %{group_id: "group_1", restricted: true, managed: true}

    %Group{}
    |> Group.changeset(group_attrs)
    |> Repo.insert!()

    member_attrs = %{group_id: "group_1", pubkey: event.pubkey, status: "member"}

    %GroupMember{}
    |> GroupMember.changeset(member_attrs)
    |> Repo.insert!()

    assert :ok = Authorization.authorize_event(event, [], enabled: true)
  end
end
