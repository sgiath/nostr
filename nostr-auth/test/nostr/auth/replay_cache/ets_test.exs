defmodule Nostr.Auth.ReplayCache.ETSTest do
  use ExUnit.Case, async: true

  alias Nostr.Auth.ReplayCache.ETS
  alias Nostr.Event

  setup do
    server = start_supervised!({ETS, window_seconds: 1})

    %{server: server}
  end

  describe "check_and_store/2" do
    test "accepts first-seen event id", %{server: server} do
      event = Event.create(27_235, content: "") |> Map.put(:id, "id-1")

      assert :ok = ETS.check_and_store(event, server: server)
      assert {:ok, first_seen_at} = ETS.first_seen_at("id-1", server: server)
      assert is_integer(first_seen_at)
    end

    test "accepts duplicate within window", %{server: server} do
      event = Event.create(27_235, content: "") |> Map.put(:id, "id-2")

      assert :ok = ETS.check_and_store(event, server: server)
      assert {:ok, first_seen_at} = ETS.first_seen_at("id-2", server: server)
      assert :ok = ETS.check_and_store(event, server: server)
      assert {:ok, ^first_seen_at} = ETS.first_seen_at("id-2", server: server)
    end

    test "rejects duplicate after window", %{server: server} do
      event = Event.create(27_235, content: "") |> Map.put(:id, "id-3")

      assert :ok = ETS.check_and_store(event, server: server, window_seconds: 0)
      assert {:error, :replayed} = ETS.check_and_store(event, server: server, window_seconds: 0)
    end

    test "returns missing_event_id for nil id", %{server: server} do
      event = Event.create(27_235, content: "")
      assert {:error, :missing_event_id} = ETS.check_and_store(event, server: server)
    end

    test "returns invalid_window_seconds for invalid override", %{server: server} do
      event = Event.create(27_235, content: "") |> Map.put(:id, "id-4")

      assert {:error, :invalid_window_seconds} =
               ETS.check_and_store(event, server: server, window_seconds: -1)
    end
  end

  describe "clear/1" do
    test "removes existing IDs", %{server: server} do
      event = Event.create(27_235, content: "") |> Map.put(:id, "id-5")

      assert :ok = ETS.check_and_store(event, server: server)
      assert {:ok, _ts} = ETS.first_seen_at("id-5", server: server)
      assert :ok = ETS.clear(server: server)
      assert {:error, :not_found} = ETS.first_seen_at("id-5", server: server)
    end
  end
end
