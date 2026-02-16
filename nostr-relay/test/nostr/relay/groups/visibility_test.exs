defmodule Nostr.Relay.Groups.VisibilityTest do
  use Nostr.Relay.DataCase, async: false

  alias Nostr.Event
  alias Nostr.Tag
  alias Nostr.Relay.Groups.Visibility
  alias Nostr.Relay.Store.Group
  alias Nostr.Relay.Store.GroupMember

  @seckey "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  setup do
    original_nip29 = Application.get_env(:nostr_relay, :nip29)

    on_exit(fn ->
      Application.put_env(:nostr_relay, :nip29, original_nip29)
    end)

    :ok
  end

  test "allows unmanaged groups when configured" do
    event =
      Event.create(1, tags: [Tag.create(:h, "group_1")], content: "hello")
      |> Event.sign(@seckey)

    assert Visibility.visible?(event, [], enabled: true, allow_unmanaged_groups: true)
  end

  test "hides private group events from non-members" do
    group_attrs = %{group_id: "group_1", managed: true, private: true}

    %Group{}
    |> Group.changeset(group_attrs)
    |> Repo.insert!()

    event =
      Event.create(1, tags: [Tag.create(:h, "group_1")], content: "hello")
      |> Event.sign(@seckey)

    refute Visibility.visible?(event, [], enabled: true, allow_unmanaged_groups: true)
  end

  test "allows private group events for members" do
    pubkey =
      Event.create(1)
      |> Event.sign(@seckey)
      |> Map.fetch!(:pubkey)

    group_attrs = %{group_id: "group_1", managed: true, private: true}

    %Group{}
    |> Group.changeset(group_attrs)
    |> Repo.insert!()

    member_attrs = %{
      group_id: "group_1",
      pubkey: pubkey,
      status: "member"
    }

    %GroupMember{}
    |> GroupMember.changeset(member_attrs)
    |> Repo.insert!()

    event =
      Event.create(1, tags: [Tag.create(:h, "group_1")], content: "hello")
      |> Event.sign(@seckey)

    assert Visibility.visible?(event, [pubkey], enabled: true, allow_unmanaged_groups: true)
  end
end
