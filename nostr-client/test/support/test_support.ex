defmodule Nostr.Client.TestSupport do
  @moduledoc false

  defmodule FakeTransport do
    @moduledoc false

    @behaviour Nostr.Client.Transport

    @impl true
    def connect(_scheme, _host, _port, opts) do
      {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid), ref: nil}}
    end

    @impl true
    def upgrade(_scheme, conn, _path, _headers, _opts) do
      {:ok, %{conn | ref: :fake_ref}, :fake_ref}
    end

    @impl true
    def new(conn, :fake_ref, 101, _headers, _opts) do
      {:ok, conn, %{test_pid: conn.test_pid}}
    end

    def new(conn, _request_ref, _status, _headers, _opts) do
      {:error, conn, :upgrade_failure}
    end

    @impl true
    def stream(conn, :upgrade_ok) do
      {:ok, conn, [{:status, :fake_ref, 101}, {:headers, :fake_ref, []}, {:done, :fake_ref}]}
    end

    def stream(conn, {:ws_data, data}) do
      {:ok, conn, [{:data, :fake_ref, data}]}
    end

    def stream(conn, {:stream_error, reason}) do
      {:error, conn, reason, []}
    end

    def stream(_conn, _message), do: :unknown

    @impl true
    def encode(websocket, {:text, payload}) do
      send(websocket.test_pid, {:fake_transport, :encoded, {:text, payload}})
      {:ok, websocket, payload}
    end

    def encode(websocket, {:pong, payload}) do
      send(websocket.test_pid, {:fake_transport, :encoded, {:pong, payload}})
      {:ok, websocket, {:pong, payload}}
    end

    def encode(websocket, :close) do
      send(websocket.test_pid, {:fake_transport, :encoded, :close})
      {:ok, websocket, :close}
    end

    @impl true
    def decode(websocket, "PING_FRAME") do
      {:ok, websocket, [{:ping, "echo-me"}]}
    end

    def decode(websocket, "CLOSE_FRAME") do
      {:ok, websocket, [{:close, 1_000, "remote-close"}]}
    end

    def decode(websocket, data) when is_binary(data) do
      {:ok, websocket, [{:text, data}]}
    end

    @impl true
    def stream_request_body(conn, :fake_ref, data) do
      send(conn.test_pid, {:fake_transport, :sent, self(), data})
      {:ok, conn}
    end

    @impl true
    def close(conn) do
      send(conn.test_pid, {:fake_transport, :closed})
      :ok
    end
  end

  defmodule TestSigner do
    @moduledoc false

    @behaviour Nostr.Client.AuthSigner

    @seckey String.duplicate("1", 64)
    @pubkey Nostr.Crypto.pubkey(@seckey)

    @spec pubkey() :: binary()
    def pubkey, do: @pubkey

    @impl true
    def sign_client_auth(pubkey, relay_url, challenge) when pubkey == @pubkey do
      auth = Nostr.Event.ClientAuth.create(relay_url, challenge, pubkey: pubkey)
      {:ok, Nostr.Event.sign(auth.event, @seckey)}
    end

    def sign_client_auth(_pubkey, _relay_url, _challenge) do
      {:error, :unknown_pubkey}
    end
  end

  @spec relay_url() :: binary()
  def relay_url do
    suffix = System.unique_integer([:positive])
    "ws://relay.example/#{suffix}"
  end

  @spec signed_event(binary()) :: Nostr.Event.t()
  def signed_event(content \\ "hello") do
    1
    |> Nostr.Event.create(pubkey: TestSigner.pubkey(), content: content)
    |> Nostr.Event.sign(String.duplicate("1", 64))
  end
end
