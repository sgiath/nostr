defmodule NostrTest do
  use ExUnit.Case, async: true

  doctest Nostr

  test "greets the world" do
    assert Nostr.hello() == :world
  end
end
