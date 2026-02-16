defmodule Nostr.Relay.Web.ConnectionStateTest do
  use ExUnit.Case, async: true

  alias Nostr.Relay.Web.ConnectionState

  describe "lifecycle" do
    test "creates an empty initial state" do
      assert %ConnectionState{messages: 0, subscriptions: subscriptions} = ConnectionState.new()
      assert map_size(subscriptions) == 0
    end

    test "converts to map form for testing" do
      state =
        ConnectionState.new()
        |> ConnectionState.add_subscription("sub-map")
        |> ConnectionState.inc_messages()

      assert %{messages: 1, subscriptions: subscriptions} = ConnectionState.to_map(state)
      assert subscriptions["sub-map"] == []
    end
  end

  describe "counters" do
    test "increments message count in an immutable way" do
      original = ConnectionState.new()
      bumped = ConnectionState.inc_messages(original)

      assert original.messages == 0
      assert bumped.messages == 1

      also_bumped = ConnectionState.inc_messages(bumped)
      assert bumped.messages == 1
      assert also_bumped.messages == 2
    end
  end

  describe "subscriptions" do
    test "adds and removes subscriptions idempotently" do
      state =
        ConnectionState.new()
        |> ConnectionState.add_subscription("sub-1")
        |> ConnectionState.add_subscription("sub-1")

      assert ConnectionState.subscription_active?(state, "sub-1")
      assert ConnectionState.subscription_count(state) == 1

      without_sub = ConnectionState.remove_subscription(state, "sub-1")

      refute ConnectionState.subscription_active?(without_sub, "sub-1")
      assert ConnectionState.subscription_count(without_sub) == 0
    end

    test "keeps independent copies from subscription operations" do
      base = ConnectionState.new()
      left = ConnectionState.add_subscription(base, "left")
      right = ConnectionState.add_subscription(base, "right")

      assert ConnectionState.subscription_active?(left, "left")
      refute ConnectionState.subscription_active?(left, "right")

      assert ConnectionState.subscription_active?(right, "right")
      refute ConnectionState.subscription_active?(right, "left")
    end
  end

  describe "auth" do
    test "defaults to auth not required and not authenticated" do
      state = ConnectionState.new()

      refute state.auth_required
      assert state.challenge == nil
      refute ConnectionState.authenticated?(state)
    end

    test "creates state with auth_required flag" do
      state = ConnectionState.new(auth_required: true)

      assert state.auth_required
      refute ConnectionState.authenticated?(state)
    end

    test "with_challenge sets the challenge string" do
      state =
        ConnectionState.new()
        |> ConnectionState.with_challenge("test-challenge-abc")

      assert state.challenge == "test-challenge-abc"
    end

    test "authenticate_pubkey adds a pubkey and marks as authenticated" do
      state =
        ConnectionState.new()
        |> ConnectionState.authenticate_pubkey("aabb")

      assert ConnectionState.authenticated?(state)
      assert ConnectionState.pubkey_authenticated?(state, "aabb")
      refute ConnectionState.pubkey_authenticated?(state, "ccdd")
    end

    test "supports multiple authenticated pubkeys per NIP-42" do
      state =
        ConnectionState.new()
        |> ConnectionState.authenticate_pubkey("pubkey1")
        |> ConnectionState.authenticate_pubkey("pubkey2")

      assert ConnectionState.authenticated?(state)
      assert ConnectionState.pubkey_authenticated?(state, "pubkey1")
      assert ConnectionState.pubkey_authenticated?(state, "pubkey2")
    end

    test "authenticate_pubkey is idempotent" do
      state =
        ConnectionState.new()
        |> ConnectionState.authenticate_pubkey("aabb")
        |> ConnectionState.authenticate_pubkey("aabb")

      assert ConnectionState.authenticated?(state)
      assert MapSet.size(state.authenticated_pubkeys) == 1
    end
  end
end
