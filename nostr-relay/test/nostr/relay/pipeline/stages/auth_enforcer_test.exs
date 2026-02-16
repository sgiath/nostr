defmodule Nostr.Relay.Pipeline.Stages.AuthEnforcerTest do
  use ExUnit.Case, async: true

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stages.AuthEnforcer
  alias Nostr.Relay.Web.ConnectionState

  @test_pubkey "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  describe "auth not required" do
    test "passes through EVENT messages" do
      context = build_context({:event, stub_event()}, auth_required: false)
      assert {:ok, ^context} = AuthEnforcer.call(context, [])
    end

    test "passes through REQ messages" do
      context = build_context({:req, "sub-1", [%Filter{}]}, auth_required: false)
      assert {:ok, ^context} = AuthEnforcer.call(context, [])
    end

    test "passes through COUNT messages" do
      context = build_context({:count, "sub-1", [%Filter{}]}, auth_required: false)
      assert {:ok, ^context} = AuthEnforcer.call(context, [])
    end
  end

  describe "auth required, not authenticated" do
    test "always passes through AUTH messages" do
      auth_event = stub_event(kind: 22_242)
      context = build_context({:auth, auth_event}, auth_required: true)
      assert {:ok, ^context} = AuthEnforcer.call(context, [])
    end

    test "rejects EVENT with OK false and auth-required prefix" do
      event = stub_event()
      context = build_context({:event, event}, auth_required: true)

      assert {:error, :auth_required, %Context{} = ctx} = AuthEnforcer.call(context, [])

      assert [{:text, ok_json}] = ctx.frames
      assert ["OK", event_id, false, "auth-required:" <> _] = JSON.decode!(ok_json)
      assert event_id == event.id
    end

    test "rejects relay-originated EVENT with OK false" do
      event = stub_event()
      context = build_context({:event, "sub-1", event}, auth_required: true)

      assert {:error, :auth_required, %Context{} = ctx} = AuthEnforcer.call(context, [])

      assert [{:text, ok_json}] = ctx.frames
      assert ["OK", event_id, false, "auth-required:" <> _] = JSON.decode!(ok_json)
      assert event_id == event.id
    end

    test "rejects REQ with CLOSED and auth-required prefix" do
      context = build_context({:req, "sub-1", [%Filter{}]}, auth_required: true)

      assert {:error, :auth_required, %Context{} = ctx} = AuthEnforcer.call(context, [])

      assert [{:text, closed_json}] = ctx.frames
      assert ["CLOSED", "sub-1", "auth-required:" <> _] = JSON.decode!(closed_json)
    end

    test "rejects COUNT with CLOSED and auth-required prefix" do
      context = build_context({:count, "count-1", [%Filter{}]}, auth_required: true)

      assert {:error, :auth_required, %Context{} = ctx} = AuthEnforcer.call(context, [])

      assert [{:text, closed_json}] = ctx.frames
      assert ["CLOSED", "count-1", "auth-required:" <> _] = JSON.decode!(closed_json)
    end

    test "passes through CLOSE messages even when unauthenticated" do
      context = build_context({:close, "sub-1"}, auth_required: true)
      assert {:ok, ^context} = AuthEnforcer.call(context, [])
    end
  end

  describe "auth required, already authenticated" do
    test "passes through EVENT messages" do
      context = build_context({:event, stub_event()}, auth_required: true, authenticated: true)
      assert {:ok, ^context} = AuthEnforcer.call(context, [])
    end

    test "passes through REQ messages" do
      context =
        build_context({:req, "sub-1", [%Filter{}]}, auth_required: true, authenticated: true)

      assert {:ok, ^context} = AuthEnforcer.call(context, [])
    end

    test "passes through COUNT messages" do
      context =
        build_context({:count, "sub-1", [%Filter{}]}, auth_required: true, authenticated: true)

      assert {:ok, ^context} = AuthEnforcer.call(context, [])
    end
  end

  defp build_context(parsed_message, opts) do
    auth_required = Keyword.get(opts, :auth_required, false)
    authenticated = Keyword.get(opts, :authenticated, false)

    state = ConnectionState.new(auth_required: auth_required)

    state =
      if authenticated,
        do: ConnectionState.authenticate_pubkey(state, @test_pubkey),
        else: state

    Context.new("{\"ignored\":\"payload\"}", state)
    |> Context.with_parsed_message(parsed_message)
  end

  defp stub_event(opts \\ []) do
    kind = Keyword.get(opts, :kind, 1)

    id =
      Keyword.get(opts, :id, "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")

    %Event{
      id: id,
      pubkey: @test_pubkey,
      kind: kind,
      tags: [],
      created_at: ~U[2024-01-01 00:00:00Z],
      content: "",
      sig: nil
    }
  end
end
