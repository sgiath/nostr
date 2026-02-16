defmodule Nostr.Relay.Pipeline.Stages.MessageHandlerAuthTest do
  use ExUnit.Case, async: false

  alias Nostr.Event
  alias Nostr.Tag
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stages.MessageHandler
  alias Nostr.Relay.Web.ConnectionState

  @seckey "1111111111111111111111111111111111111111111111111111111111111111"
  @pubkey Nostr.Crypto.pubkey(@seckey)
  @challenge "test-challenge-abc123"
  @relay_url "wss://relay.example.com"

  setup do
    original_auth = Application.get_env(:nostr_relay, :auth)
    original_relay_info = Application.get_env(:nostr_relay, :relay_info)
    original_server = Application.get_env(:nostr_relay, :server)

    on_exit(fn ->
      Application.put_env(:nostr_relay, :auth, original_auth)
      Application.put_env(:nostr_relay, :relay_info, original_relay_info)
      Application.put_env(:nostr_relay, :server, original_server)
    end)

    set_relay_url(@relay_url)
    set_auth_config(mode: :none, whitelist: [], denylist: [])

    :ok
  end

  describe "AUTH event handling" do
    test "valid auth event authenticates the pubkey" do
      event = auth_event()
      context = build_auth_context(event)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      assert ConnectionState.authenticated?(ctx.connection_state)
      assert ConnectionState.pubkey_authenticated?(ctx.connection_state, @pubkey)
      assert_ok_frame(ctx, event.id, true)
    end

    test "rejects auth event with wrong challenge" do
      event = auth_event(challenge: "wrong-challenge")
      context = build_auth_context(event)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      refute ConnectionState.authenticated?(ctx.connection_state)
      assert_ok_frame(ctx, event.id, false, "auth-required: challenge mismatch")
    end

    test "rejects auth event with wrong relay URL" do
      event = auth_event(relay: "wss://other-relay.com")
      context = build_auth_context(event)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      refute ConnectionState.authenticated?(ctx.connection_state)
      assert_ok_frame(ctx, event.id, false, "auth-required: relay URL mismatch")
    end

    test "rejects auth event with expired timestamp" do
      old_time = DateTime.add(DateTime.utc_now(), -700, :second)
      event = auth_event(created_at: old_time)
      context = build_auth_context(event)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      refute ConnectionState.authenticated?(ctx.connection_state)
      assert_ok_frame(ctx, event.id, false, "auth-required: event too old")
    end

    test "validates relay URL against derived server config when no explicit URL set" do
      clear_relay_url()
      set_server(ip: {127, 0, 0, 1}, port: 4000, scheme: :http)

      # Derived URL is ws://127.0.0.1:4000 — matching relay tag should pass
      event = auth_event(relay: "ws://127.0.0.1:4000")
      context = build_auth_context(event)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      assert ConnectionState.authenticated?(ctx.connection_state)
      assert_ok_frame(ctx, event.id, true)
    end

    test "rejects auth event when derived relay URL does not match" do
      clear_relay_url()
      set_server(ip: {127, 0, 0, 1}, port: 4000, scheme: :http)

      event = auth_event(relay: "wss://other-relay.example.com")
      context = build_auth_context(event)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      refute ConnectionState.authenticated?(ctx.connection_state)
      assert_ok_frame(ctx, event.id, false, "auth-required: relay URL mismatch")
    end

    test "skips relay check only when no URL configured and no server config" do
      clear_relay_url()
      clear_server()

      event = auth_event(relay: "wss://any-relay.example.com")
      context = build_auth_context(event)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      assert ConnectionState.authenticated?(ctx.connection_state)
      assert_ok_frame(ctx, event.id, true)
    end

    test "rejects auth event when no challenge was issued" do
      event = auth_event()
      state = ConnectionState.new()
      context = build_context({:auth, event}, state)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      refute ConnectionState.authenticated?(ctx.connection_state)
      assert_ok_frame(ctx, event.id, false, "auth-required: no challenge issued")
    end

    test "ignores relay-to-client AUTH challenge string gracefully" do
      state = ConnectionState.new()
      context = build_context({:auth, "some-challenge-string"}, state)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      refute ConnectionState.authenticated?(ctx.connection_state)
      assert ctx.frames == []
    end

    test "rejects auth event with wrong kind" do
      event =
        1
        |> Event.create(
          tags: [Tag.create(:relay, @relay_url), Tag.create(:challenge, @challenge)],
          created_at: DateTime.utc_now()
        )
        |> Event.sign(@seckey)

      context = build_auth_context(event)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      refute ConnectionState.authenticated?(ctx.connection_state)
      assert_ok_frame(ctx, event.id, false, "auth-required: invalid auth event kind")
    end
  end

  describe "whitelist/denylist enforcement" do
    test "rejects pubkey not on whitelist" do
      set_auth_config(mode: :whitelist, whitelist: ["other_pubkey"])
      event = auth_event()
      context = build_auth_context(event)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      refute ConnectionState.authenticated?(ctx.connection_state)
      assert_ok_frame(ctx, event.id, false, "restricted: not on whitelist")
    end

    test "accepts pubkey on whitelist" do
      set_auth_config(mode: :whitelist, whitelist: [@pubkey])
      event = auth_event()
      context = build_auth_context(event)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      assert ConnectionState.authenticated?(ctx.connection_state)
      assert_ok_frame(ctx, event.id, true)
    end

    test "rejects pubkey on denylist" do
      set_auth_config(mode: :denylist, denylist: [@pubkey])
      event = auth_event()
      context = build_auth_context(event)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      refute ConnectionState.authenticated?(ctx.connection_state)
      assert_ok_frame(ctx, event.id, false, "restricted: pubkey denied")
    end

    test "accepts pubkey not on denylist" do
      set_auth_config(mode: :denylist, denylist: ["other_pubkey"])
      event = auth_event()
      context = build_auth_context(event)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      assert ConnectionState.authenticated?(ctx.connection_state)
      assert_ok_frame(ctx, event.id, true)
    end

    test "no list enforcement when mode is :none" do
      set_auth_config(mode: :none, whitelist: ["other_pubkey"], denylist: [@pubkey])
      event = auth_event()
      context = build_auth_context(event)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      assert ConnectionState.authenticated?(ctx.connection_state)
      assert_ok_frame(ctx, event.id, true)
    end
  end

  describe "kind 22242 blocking via EVENT" do
    test "rejects kind 22242 sent via EVENT message" do
      event = auth_event()
      state = ConnectionState.new()
      context = build_context({:event, event}, state)

      assert {:ok, %Context{} = ctx} = MessageHandler.call(context, [])

      assert_ok_frame(ctx, event.id, false, "blocked: kind 22242 not accepted via EVENT")
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp auth_event(opts \\ []) do
    challenge = Keyword.get(opts, :challenge, @challenge)
    relay = Keyword.get(opts, :relay, @relay_url)
    created_at = Keyword.get(opts, :created_at, DateTime.utc_now())

    tags = [
      Tag.create(:relay, relay),
      Tag.create(:challenge, challenge)
    ]

    22_242
    |> Event.create(tags: tags, created_at: created_at)
    |> Event.sign(@seckey)
  end

  defp build_auth_context(event) do
    state =
      ConnectionState.new()
      |> ConnectionState.with_challenge(@challenge)

    build_context({:auth, event}, state)
  end

  defp build_context(parsed_message, state) do
    Context.new("{\"ignored\":\"payload\"}", state)
    |> Context.with_parsed_message(parsed_message)
  end

  defp set_relay_url(url) do
    info = Application.get_env(:nostr_relay, :relay_info, [])
    Application.put_env(:nostr_relay, :relay_info, Keyword.put(info, :url, url))
  end

  defp clear_relay_url do
    info = Application.get_env(:nostr_relay, :relay_info, [])
    Application.put_env(:nostr_relay, :relay_info, Keyword.delete(info, :url))
  end

  defp set_server(opts) do
    current = Application.get_env(:nostr_relay, :server, [])
    Application.put_env(:nostr_relay, :server, Keyword.merge(current, opts))
  end

  defp clear_server do
    Application.put_env(:nostr_relay, :server, [])
  end

  defp set_auth_config(opts) do
    current = Application.get_env(:nostr_relay, :auth, [])

    updated =
      current
      |> Keyword.merge(opts)

    Application.put_env(:nostr_relay, :auth, updated)
  end

  defp assert_ok_frame(%Context{frames: frames}, event_id, expected_success) do
    assert [{:text, ok_json}] = frames
    decoded = JSON.decode!(ok_json)
    assert ["OK", ^event_id, ^expected_success, _message] = decoded
  end

  defp assert_ok_frame(%Context{frames: frames}, event_id, expected_success, expected_message) do
    assert [{:text, ok_json}] = frames
    decoded = JSON.decode!(ok_json)
    assert ["OK", ^event_id, ^expected_success, ^expected_message] = decoded
  end
end
