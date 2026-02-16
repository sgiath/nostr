defmodule Nostr.Relay.Pipeline.Stages.StorePolicyTest do
  use ExUnit.Case, async: true

  alias Nostr.Event
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stages.StorePolicy
  alias Nostr.Relay.Web.ConnectionState
  alias Nostr.Tag

  @event_pubkey "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @other_pubkey "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  describe "NIP-70 protected events" do
    test "rejects protected event when connection is unauthenticated" do
      event = stub_event(tags: [Tag.create("-")])
      context = build_context({:event, event}, ConnectionState.new())

      assert {:error, :nip70_protected_event_unauthorized, %Context{} = rejected_context} =
               StorePolicy.call(context, [])

      assert rejected_context.error == :nip70_protected_event_unauthorized
      assert_ok_frame(rejected_context, event.id, false)
    end

    test "rejects protected event when authenticated pubkey does not match author" do
      event = stub_event(tags: [Tag.create("-")])

      state =
        ConnectionState.new()
        |> ConnectionState.authenticate_pubkey(@other_pubkey)

      context = build_context({:event, event}, state)

      assert {:error, :nip70_protected_event_unauthorized, %Context{} = rejected_context} =
               StorePolicy.call(context, [])

      assert rejected_context.error == :nip70_protected_event_unauthorized
      assert_ok_frame(rejected_context, event.id, false)
    end

    test "accepts protected event when authenticated pubkey matches author" do
      event = stub_event(tags: [Tag.create("-")])

      state =
        ConnectionState.new()
        |> ConnectionState.authenticate_pubkey(event.pubkey)

      context = build_context({:event, event}, state)

      assert {:ok, %Context{} = accepted_context} = StorePolicy.call(context, [])
      assert accepted_context.frames == []
      assert accepted_context.error == nil
    end

    test "accepts protected relay-originated event when authenticated pubkey matches author" do
      event = stub_event(tags: [Tag.create("-")])

      state =
        ConnectionState.new()
        |> ConnectionState.authenticate_pubkey(event.pubkey)

      context = build_context({:event, "relay-internal", event}, state)

      assert {:ok, %Context{} = accepted_context} = StorePolicy.call(context, [])
      assert accepted_context.frames == []
      assert accepted_context.error == nil
    end

    test "accepts non-protected events regardless of auth state" do
      event = stub_event(tags: [Tag.create(:p, @other_pubkey)])
      context = build_context({:event, event}, ConnectionState.new())

      assert {:ok, %Context{} = accepted_context} = StorePolicy.call(context, [])
      assert accepted_context.frames == []
      assert accepted_context.error == nil
    end
  end

  defp assert_ok_frame(%Context{frames: frames}, event_id, success?) do
    assert [{:text, ok_json}] = frames

    assert [
             "OK",
             ^event_id,
             ^success?,
             "auth-required: protected event requires matching authenticated pubkey"
           ] = JSON.decode!(ok_json)
  end

  defp build_context(parsed_message, %ConnectionState{} = state) do
    Context.new("{\"ignored\":\"payload\"}", state)
    |> Context.with_parsed_message(parsed_message)
  end

  defp stub_event(opts) do
    kind = Keyword.get(opts, :kind, 1)
    tags = Keyword.get(opts, :tags, [])

    %Event{
      id: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
      pubkey: @event_pubkey,
      kind: kind,
      tags: tags,
      created_at: ~U[2024-01-01 00:00:00Z],
      content: "",
      sig: nil
    }
  end
end
