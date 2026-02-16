defmodule Nostr.Relay.Pipeline.Stages.GroupPolicyValidatorTest do
  use Nostr.Relay.DataCase, async: false

  alias Nostr.Event
  alias Nostr.Message
  alias Nostr.Tag
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stages.GroupPolicyValidator
  alias Nostr.Relay.Web.ConnectionState

  @seckey "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  setup do
    original_nip29 = Application.get_env(:nostr_relay, :nip29)
    original_relay_info = Application.get_env(:nostr_relay, :relay_info)

    on_exit(fn ->
      Application.put_env(:nostr_relay, :nip29, original_nip29)
      Application.put_env(:nostr_relay, :relay_info, original_relay_info)
    end)

    :ok
  end

  test "passes through when nip29 is disabled" do
    Application.put_env(:nostr_relay, :nip29, enabled: false)

    event =
      Event.create(9_000, tags: [], content: "mod action")
      |> Event.sign(@seckey)

    assert {:ok, _context} =
             {:event, event}
             |> build_context()
             |> GroupPolicyValidator.call([])
  end

  test "rejects management events missing h tag when enabled" do
    Application.put_env(:nostr_relay, :nip29, enabled: true)

    event =
      Event.create(9_000, tags: [], content: "mod action")
      |> Event.sign(@seckey)

    assert {:error, :nip29_rejected, %Context{frames: [{:text, ok_json}]}} =
             {:event, event}
             |> build_context()
             |> GroupPolicyValidator.call([])

    assert ["OK", returned_id, false, message] = JSON.decode!(ok_json)
    assert returned_id == event.id
    assert message == "invalid: group event requires h tag"
  end

  test "accepts management events with h tag when unmanaged groups are allowed" do
    Application.put_env(:nostr_relay, :nip29, enabled: true, allow_unmanaged_groups: true)

    event =
      Event.create(9_021, tags: [Tag.create(:h, "group_1")], content: "join")
      |> Event.sign(@seckey)

    assert {:ok, _context} =
             {:event, event}
             |> build_context()
             |> GroupPolicyValidator.call([])
  end

  defp build_context(parsed_message) do
    payload = Message.serialize(Message.notice("noop"))

    Context.new(payload, ConnectionState.new())
    |> Context.with_parsed_message(parsed_message)
  end
end
