defmodule Nostr.NIP29Test do
  use ExUnit.Case, async: true

  alias Nostr.Event
  alias Nostr.NIP29
  alias Nostr.Tag

  describe "kind helpers" do
    test "classifies NIP-29 kinds" do
      assert NIP29.join_request_kind?(9_021)
      assert NIP29.leave_request_kind?(9_022)
      assert NIP29.moderation_kind?(9_000)
      assert NIP29.moderation_kind?(9_020)
      assert NIP29.metadata_kind?(39_000)
      assert NIP29.metadata_kind?(39_003)

      refute NIP29.moderation_kind?(9_021)
      refute NIP29.metadata_kind?(39_004)
    end

    test "reports required tag type by kind" do
      assert NIP29.requires_h_tag?(9_000)
      assert NIP29.requires_h_tag?(9_022)
      refute NIP29.requires_h_tag?(39_000)

      assert NIP29.requires_d_tag?(39_000)
      assert NIP29.requires_d_tag?(39_003)
      refute NIP29.requires_d_tag?(9_000)
    end
  end

  describe "group id extraction" do
    test "extracts group id from h tag" do
      event = Event.create(1, tags: [Tag.create(:h, "group-1")])

      assert NIP29.group_id_from_h(event) == "group-1"
      assert NIP29.group_id(event) == "group-1"
    end

    test "extracts group id from d tag for metadata kinds" do
      event = Event.create(39_000, tags: [Tag.create(:d, "pizza")])

      assert NIP29.group_id_from_d(event) == "pizza"
      assert NIP29.group_id(event) == "pizza"
    end
  end

  describe "previous refs" do
    test "collects previous refs from data and info" do
      event =
        Event.create(9_000,
          tags: [
            %Tag{type: :previous, data: "aa11bb22", info: ["cc33dd44"]},
            %Tag{type: :previous, data: "ee55ff66", info: []}
          ]
        )

      assert NIP29.previous_refs(event) == ["aa11bb22", "cc33dd44", "ee55ff66"]
    end
  end

  describe "moderation targets" do
    test "extracts p/e/a/code targets" do
      event =
        Event.create(9_000,
          tags: [
            Tag.create(:p, "pubkey"),
            Tag.create(:e, "event-id"),
            Tag.create(:a, "30023:pubkey:d"),
            Tag.create(:code, "invite123")
          ]
        )

      assert NIP29.moderation_targets(event) == %{
               p: ["pubkey"],
               e: ["event-id"],
               a: ["30023:pubkey:d"],
               code: ["invite123"]
             }
    end
  end

  describe "required tag validation" do
    test "validates required h tags" do
      event = Event.create(9_021, tags: [Tag.create(:h, "group_1")])

      assert {:ok, "group_1"} = NIP29.validate_required_group_tag(event)

      missing = Event.create(9_021, tags: [])
      assert {:error, :missing_h_tag} = NIP29.validate_required_group_tag(missing)
    end

    test "validates required d tags" do
      event = Event.create(39_001, tags: [Tag.create(:d, "group-1")])

      assert {:ok, "group-1"} = NIP29.validate_required_group_tag(event)

      missing = Event.create(39_001, tags: [])
      assert {:error, :missing_d_tag} = NIP29.validate_required_group_tag(missing)
    end

    test "enforces strict group id format when enabled" do
      event = Event.create(9_000, tags: [Tag.create(:h, "Group Name")])

      assert {:error, :invalid_group_id} =
               NIP29.validate_required_group_tag(event, strict_group_ids: true)
    end
  end
end
