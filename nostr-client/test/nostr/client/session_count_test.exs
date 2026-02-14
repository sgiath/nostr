defmodule Nostr.Client.SessionCountTest do
  use ExUnit.Case, async: false

  alias Nostr.Client
  alias Nostr.Client.TestSupport

  describe "count_session/3" do
    test "fans out to readable relays and returns per-relay results" do
      relay_a = TestSupport.relay_url()
      relay_b = TestSupport.relay_url()

      {:ok, session_pid} =
        Client.start_session(
          pubkey: TestSupport.TestSigner.pubkey(),
          signer: TestSupport.TestSigner,
          transport: TestSupport.FakeTransport,
          transport_opts: [test_pid: self()],
          notify: self(),
          relays: [{relay_a, :read}, {relay_b, :read_write}]
        )

      assert {:ok, relays} = Client.list_relays(session_pid)

      Enum.each(relays, fn relay ->
        send(relay.session_pid, :upgrade_ok)
      end)

      assert_receive {:nostr_client, :connected, _pid, _relay_url}
      assert_receive {:nostr_client, :connected, _pid, _relay_url}

      task = Task.async(fn -> Client.count_session(session_pid, [%Nostr.Filter{kinds: [1]}]) end)

      assert_receive {:fake_transport, :sent, relay_pid_a, payload_a}
      assert {:count, query_id_a, [%Nostr.Filter{kinds: [1]}]} = Nostr.Message.parse(payload_a)

      assert_receive {:fake_transport, :sent, relay_pid_b, payload_b}
      assert {:count, query_id_b, [%Nostr.Filter{kinds: [1]}]} = Nostr.Message.parse(payload_b)

      query_id_by_relay_pid = %{relay_pid_a => query_id_a, relay_pid_b => query_id_b}

      Enum.each(relays, fn relay ->
        query_id = Map.fetch!(query_id_by_relay_pid, relay.session_pid)

        if relay.relay_url == relay_a do
          count_a = {:count, query_id, %{count: 2}} |> Nostr.Message.serialize()
          send(relay.session_pid, {:ws_data, count_a})
        else
          closed_b =
            Nostr.Message.closed(query_id, "error: count disabled") |> Nostr.Message.serialize()

          send(relay.session_pid, {:ws_data, closed_b})
        end
      end)

      assert {:ok, result_map} = Task.await(task)
      assert Map.keys(result_map) |> Enum.sort() == Enum.sort([relay_a, relay_b])
      assert result_map[relay_a] == {:ok, %{count: 2}}
      assert result_map[relay_b] == {:error, {:closed, "error: count disabled"}}

      assert :ok = Client.stop_session(session_pid)
    end

    test "returns error when there are no readable relays" do
      {:ok, session_pid} =
        Client.start_session(
          pubkey: TestSupport.TestSigner.pubkey(),
          signer: TestSupport.TestSigner,
          transport: TestSupport.FakeTransport,
          transport_opts: [test_pid: self()]
        )

      assert {:error, :no_readable_relays} =
               Client.count_session(session_pid, [%Nostr.Filter{kinds: [1]}])

      assert :ok = Client.stop_session(session_pid)
    end
  end

  describe "count_session_hll/3" do
    test "returns relay results plus aggregated HLL estimate" do
      relay_a = TestSupport.relay_url()
      relay_b = TestSupport.relay_url()

      {:ok, session_pid} =
        Client.start_session(
          pubkey: TestSupport.TestSigner.pubkey(),
          signer: TestSupport.TestSigner,
          transport: TestSupport.FakeTransport,
          transport_opts: [test_pid: self()],
          notify: self(),
          relays: [{relay_a, :read}, {relay_b, :read_write}]
        )

      assert {:ok, relays} = Client.list_relays(session_pid)

      Enum.each(relays, fn relay ->
        send(relay.session_pid, :upgrade_ok)
      end)

      assert_receive {:nostr_client, :connected, _pid, _relay_url}
      assert_receive {:nostr_client, :connected, _pid, _relay_url}

      filter = Nostr.Filter.parse(%{"kinds" => [7], "#e" => [String.duplicate("a", 64)]})
      {:ok, base_hll} = Nostr.NIP45.new_from_filter(filter)
      {:ok, hll_a} = Nostr.NIP45.add_pubkey(base_hll, String.duplicate("1", 64))
      {:ok, hll_b} = Nostr.NIP45.add_pubkey(base_hll, String.duplicate("2", 64))

      task = Task.async(fn -> Client.count_session_hll(session_pid, filter) end)

      assert_receive {:fake_transport, :sent, relay_pid_a, payload_a}
      assert {:count, query_id_a, [_]} = Nostr.Message.parse(payload_a)

      assert_receive {:fake_transport, :sent, relay_pid_b, payload_b}
      assert {:count, query_id_b, [_]} = Nostr.Message.parse(payload_b)

      query_id_by_relay_pid = %{relay_pid_a => query_id_a, relay_pid_b => query_id_b}

      Enum.each(relays, fn relay ->
        query_id = Map.fetch!(query_id_by_relay_pid, relay.session_pid)

        if relay.relay_url == relay_a do
          count_a =
            {:count, query_id, %{count: 2, hll: Nostr.NIP45.to_hex(hll_a)}}
            |> Nostr.Message.serialize()

          send(relay.session_pid, {:ws_data, count_a})
        else
          count_b =
            {:count, query_id, %{count: 3, hll: Nostr.NIP45.to_hex(hll_b)}}
            |> Nostr.Message.serialize()

          send(relay.session_pid, {:ws_data, count_b})
        end
      end)

      assert {:ok, %{relay_results: relay_results, aggregate: aggregate}} = Task.await(task)
      assert Map.keys(relay_results) |> Enum.sort() == Enum.sort([relay_a, relay_b])
      assert relay_results[relay_a] == {:ok, %{count: 2, hll: Nostr.NIP45.to_hex(hll_a)}}
      assert relay_results[relay_b] == {:ok, %{count: 3, hll: Nostr.NIP45.to_hex(hll_b)}}
      assert aggregate.fallback_sum == 5
      assert aggregate.used_hll_count == 2
      assert is_integer(aggregate.estimate)
      assert aggregate.estimate > 0
      assert is_binary(aggregate.hll)

      assert :ok = Client.stop_session(session_pid)
    end

    test "requires a single filter" do
      {:ok, session_pid} =
        Client.start_session(
          pubkey: TestSupport.TestSigner.pubkey(),
          signer: TestSupport.TestSigner,
          transport: TestSupport.FakeTransport,
          transport_opts: [test_pid: self()]
        )

      assert {:error, :single_filter_required} =
               Client.count_session_hll(session_pid, [
                 %Nostr.Filter{kinds: [1]},
                 %Nostr.Filter{kinds: [7]}
               ])

      assert :ok = Client.stop_session(session_pid)
    end
  end
end
