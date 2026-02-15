defmodule Nostr.Relay.Web.ConnectionStateTest do
  use ExUnit.Case, async: true

  alias Nostr.Relay.Web.ConnectionState

  describe "lifecycle" do
    test "creates an empty initial state" do
      assert %ConnectionState{messages: 0, subscriptions: subscriptions} = ConnectionState.new()
      assert MapSet.size(subscriptions) == 0
    end

    test "converts to map form for testing" do
      state =
        ConnectionState.new()
        |> ConnectionState.add_subscription("sub-map")
        |> ConnectionState.inc_messages()

      assert %{messages: 1, subscriptions: subscriptions} = ConnectionState.to_map(state)
      assert MapSet.member?(subscriptions, "sub-map")
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
end
