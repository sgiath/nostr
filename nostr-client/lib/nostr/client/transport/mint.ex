defmodule Nostr.Client.Transport.Mint do
  @moduledoc false

  @behaviour Nostr.Client.Transport

  @impl true
  @spec connect(:http | :https, String.t(), :inet.port_number(), Keyword.t()) ::
          {:ok, Mint.HTTP.t()} | {:error, term()}
  def connect(scheme, host, port, opts) do
    Mint.HTTP.connect(scheme, host, port, opts)
  end

  @impl true
  @spec upgrade(:ws | :wss, Mint.HTTP.t(), String.t(), Mint.Types.headers(), Keyword.t()) ::
          {:ok, Mint.HTTP.t(), Mint.Types.request_ref()}
          | {:error, Mint.HTTP.t(), Mint.WebSocket.error()}
  def upgrade(scheme, conn, path, headers, opts) do
    Mint.WebSocket.upgrade(scheme, conn, path, headers, opts)
  end

  @impl true
  @spec new(
          Mint.HTTP.t(),
          Mint.Types.request_ref(),
          Mint.Types.status(),
          Mint.Types.headers(),
          Keyword.t()
        ) ::
          {:ok, Mint.HTTP.t(), Mint.WebSocket.t()}
          | {:error, Mint.HTTP.t(), Mint.WebSocket.error()}
  def new(conn, request_ref, status, response_headers, opts) do
    Mint.WebSocket.new(conn, request_ref, status, response_headers, opts)
  end

  @impl true
  @spec stream(Mint.HTTP.t(), term()) ::
          {:ok, Mint.HTTP.t(), [Mint.Types.response()]}
          | {:error, Mint.HTTP.t(), Mint.Types.error(), [Mint.Types.response()]}
          | :unknown
  def stream(conn, message) do
    Mint.WebSocket.stream(conn, message)
  end

  @impl true
  @spec encode(Mint.WebSocket.t(), Mint.WebSocket.shorthand_frame() | Mint.WebSocket.frame()) ::
          {:ok, Mint.WebSocket.t(), binary()} | {:error, Mint.WebSocket.t(), term()}
  def encode(websocket, frame) do
    Mint.WebSocket.encode(websocket, frame)
  end

  @impl true
  @spec decode(Mint.WebSocket.t(), binary()) ::
          {:ok, Mint.WebSocket.t(), [Mint.WebSocket.frame() | {:error, term()}]}
          | {:error, Mint.WebSocket.t(), term()}
  def decode(websocket, data) do
    Mint.WebSocket.decode(websocket, data)
  end

  @impl true
  @spec stream_request_body(Mint.HTTP.t(), Mint.Types.request_ref(), iodata()) ::
          {:ok, Mint.HTTP.t()} | {:error, Mint.HTTP.t(), Mint.WebSocket.error()}
  def stream_request_body(conn, request_ref, data) do
    Mint.WebSocket.stream_request_body(conn, request_ref, data)
  end

  @impl true
  @spec close(Mint.HTTP.t()) :: :ok
  def close(conn) do
    Mint.HTTP.close(conn)
  end
end
