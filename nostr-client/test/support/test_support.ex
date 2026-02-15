defmodule Nostr.Client.TestSupport do
  @moduledoc false

  alias Nostr.Client.SessionKey

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

  @spec relay_available?(binary()) :: :ok | {:error, term()}
  def relay_available?(relay_url) when is_binary(relay_url) do
    uri = URI.parse(relay_url)
    host = uri.host
    port = uri.port || default_port(uri.scheme)

    if is_binary(host) && is_integer(port) do
      case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 2_000) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_relay_url}
    end
  end

  @spec default_port(String.t() | nil) :: 443 | 80
  defp default_port("wss"), do: 443
  defp default_port("ws"), do: 80
  defp default_port(_), do: 80

  @spec wait_for_connected(pid(), binary(), pos_integer()) :: :ok | {:error, term()}
  def wait_for_connected(pid, relay_url), do: wait_for_connected(pid, relay_url, 15_000)

  def wait_for_connected(pid, relay_url, timeout_ms)
      when is_pid(pid) and is_binary(relay_url) and is_integer(timeout_ms) and timeout_ms > 0 do
    expected = normalize_relay_url(relay_url)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait_for_connected(pid, expected, deadline)
  end

  defp do_wait_for_connected(pid, expected_relay_url, deadline_ms) do
    if relay_session_connected?(pid) or session_connected?(pid, expected_relay_url) do
      :ok
    else
      now = System.monotonic_time(:millisecond)
      remaining = deadline_ms - now

      if remaining <= 0 do
        {:error, :timeout}
      else
        receive do
          {:nostr_client, :connected, ^pid, relay_url} ->
            if normalize_relay_url(relay_url) == expected_relay_url,
              do: :ok,
              else: do_wait_for_connected(pid, expected_relay_url, deadline_ms)

          {:nostr_client, :disconnected, ^pid, _reason} ->
            {:error, :disconnected}
        after
          min(remaining, 500) ->
            do_wait_for_connected(pid, expected_relay_url, deadline_ms)
        end
      end
    end
  end

  defp relay_session_connected?(pid) do
    case process_state(pid) do
      %{phase: :connected} -> true
      _other -> false
    end
  end

  defp session_connected?(pid, expected_relay_url) do
    case process_state(pid) do
      %{relays: relays} when is_map(relays) ->
        relays
        |> Map.values()
        |> Enum.any?(fn
          %{relay_url: relay_url, session_pid: relay_pid} ->
            normalize_relay_url(relay_url) == expected_relay_url and
              relay_session_connected?(relay_pid)

          _entry ->
            false
        end)

      _other ->
        false
    end
  end

  defp process_state(pid) do
    try do
      :sys.get_state(pid)
    catch
      _kind, _reason -> nil
    end
  end

  defp normalize_relay_url(relay_url) when is_binary(relay_url) do
    case SessionKey.normalize_relay_url(relay_url) do
      {:ok, normalized_relay_url} -> normalized_relay_url
      {:error, _} -> relay_url
    end
  end
end
