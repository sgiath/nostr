defmodule Nostr.Client.ClientNegentropyTest do
  use ExUnit.Case, async: false

  alias Nostr.Client
  alias Nostr.Client.RelaySession
  alias Nostr.Client.TestSupport

  describe "neg_open/6 + neg_msg/5 + neg_close/4" do
    test "runs a full negentropy exchange via public API" do
      relay_url = TestSupport.relay_url()
      opts = session_opts()

      {:ok, session_pid} = Client.get_or_start_session(relay_url, opts)
      send(session_pid, :upgrade_ok)
      assert_receive {:nostr_client, :connected, ^session_pid, ^relay_url}

      open_task =
        Task.async(fn ->
          Client.neg_open(relay_url, "neg-1", %Nostr.Filter{kinds: [1]}, "00", opts)
        end)

      assert_receive {:fake_transport, :sent, _relay_pid, open_payload}

      assert {:neg_open, "neg-1", %Nostr.Filter{kinds: [1]}, "00"} =
               Nostr.Message.parse(open_payload)

      send(
        session_pid,
        {:ws_data, Nostr.Message.neg_msg("neg-1", "aa") |> Nostr.Message.serialize()}
      )

      assert {:ok, "aa"} == Task.await(open_task)

      msg_task = Task.async(fn -> Client.neg_msg(relay_url, "neg-1", "bb", opts) end)
      assert_receive {:fake_transport, :sent, _relay_pid, msg_payload}
      assert {:neg_msg, "neg-1", "bb"} = Nostr.Message.parse(msg_payload)

      send(
        session_pid,
        {:ws_data, Nostr.Message.neg_msg("neg-1", "cc") |> Nostr.Message.serialize()}
      )

      assert {:ok, "cc"} == Task.await(msg_task)

      assert :ok == Client.neg_close(relay_url, "neg-1", opts)
      assert_receive {:fake_transport, :sent, _relay_pid, close_payload}
      assert {:neg_close, "neg-1"} = Nostr.Message.parse(close_payload)

      assert :ok == RelaySession.close(session_pid)
      assert_receive {:nostr_client, :disconnected, ^session_pid, :normal}
    end

    test "returns not_connected before websocket upgrade" do
      relay_url = TestSupport.relay_url()
      opts = session_opts()

      {:ok, session_pid} = Client.get_or_start_session(relay_url, opts)

      assert {:error, :not_connected} ==
               Client.neg_open(relay_url, "neg-1", %Nostr.Filter{kinds: [1]}, "00", opts)

      assert {:error, :not_connected} == Client.neg_msg(relay_url, "neg-1", "00", opts)
      assert {:error, :not_connected} == Client.neg_close(relay_url, "neg-1", opts)

      assert :ok == RelaySession.close(session_pid)
      assert_receive {:nostr_client, :disconnected, ^session_pid, :normal}
    end

    test "propagates blocked NEG-ERR through client API" do
      relay_url = TestSupport.relay_url()
      opts = session_opts()

      {:ok, session_pid} = Client.get_or_start_session(relay_url, opts)
      send(session_pid, :upgrade_ok)
      assert_receive {:nostr_client, :connected, ^session_pid, ^relay_url}

      open_task =
        Task.async(fn ->
          Client.neg_open(relay_url, "neg-1", %Nostr.Filter{kinds: [1]}, "00", opts)
        end)

      assert_receive {:fake_transport, :sent, _relay_pid, _open_payload}

      send(
        session_pid,
        {:ws_data,
         Nostr.Message.neg_err("neg-1", "blocked: query too big") |> Nostr.Message.serialize()}
      )

      assert {:error, {:neg_err, :blocked, "blocked: query too big"}} == Task.await(open_task)

      assert :ok == RelaySession.close(session_pid)
      assert_receive {:nostr_client, :disconnected, ^session_pid, :normal}
    end

    test "propagates neg_msg_already_pending when turn is outstanding" do
      relay_url = TestSupport.relay_url()
      opts = session_opts()

      {:ok, session_pid} = Client.get_or_start_session(relay_url, opts)
      send(session_pid, :upgrade_ok)
      assert_receive {:nostr_client, :connected, ^session_pid, ^relay_url}

      open_task =
        Task.async(fn ->
          Client.neg_open(relay_url, "neg-1", %Nostr.Filter{kinds: [1]}, "00", opts)
        end)

      assert_receive {:fake_transport, :sent, _relay_pid, _open_payload}

      send(
        session_pid,
        {:ws_data, Nostr.Message.neg_msg("neg-1", "aa") |> Nostr.Message.serialize()}
      )

      assert {:ok, "aa"} == Task.await(open_task)

      msg_task = Task.async(fn -> Client.neg_msg(relay_url, "neg-1", "bb", opts) end)
      assert_receive {:fake_transport, :sent, _relay_pid, _msg_payload}

      assert {:error, :neg_msg_already_pending} == Client.neg_msg(relay_url, "neg-1", "cc", opts)

      send(
        session_pid,
        {:ws_data, Nostr.Message.neg_msg("neg-1", "dd") |> Nostr.Message.serialize()}
      )

      assert {:ok, "dd"} == Task.await(msg_task)

      assert :ok == RelaySession.close(session_pid)
      assert_receive {:nostr_client, :disconnected, ^session_pid, :normal}
    end

    test "returns session_stopped for pending NEG-OPEN when session closes" do
      relay_url = TestSupport.relay_url()
      opts = session_opts()

      {:ok, session_pid} = Client.get_or_start_session(relay_url, opts)
      send(session_pid, :upgrade_ok)
      assert_receive {:nostr_client, :connected, ^session_pid, ^relay_url}

      open_task =
        Task.async(fn ->
          Client.neg_open(relay_url, "neg-1", %Nostr.Filter{kinds: [1]}, "00", opts)
        end)

      assert_receive {:fake_transport, :sent, _relay_pid, _open_payload}

      assert :ok == RelaySession.close(session_pid)
      assert_receive {:nostr_client, :disconnected, ^session_pid, :normal}

      assert {:error, {:session_stopped, :normal}} == Task.await(open_task)
    end
  end

  defp session_opts do
    [
      pubkey: TestSupport.TestSigner.pubkey(),
      signer: TestSupport.TestSigner,
      transport: TestSupport.FakeTransport,
      transport_opts: [test_pid: self()],
      notify: self()
    ]
  end
end
