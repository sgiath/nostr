defmodule Nostr.Client.Transport do
  @moduledoc false

  @type connection() :: term()
  @type websocket() :: term()
  @type request_ref() :: term()
  @type response() :: term()

  @callback connect(:http | :https, String.t(), :inet.port_number(), Keyword.t()) ::
              {:ok, connection()} | {:error, term()}

  @callback upgrade(:ws | :wss, connection(), String.t(), Mint.Types.headers(), Keyword.t()) ::
              {:ok, connection(), request_ref()} | {:error, connection(), term()}

  @callback new(
              connection(),
              request_ref(),
              Mint.Types.status(),
              Mint.Types.headers(),
              Keyword.t()
            ) ::
              {:ok, connection(), websocket()} | {:error, connection(), term()}

  @callback stream(connection(), term()) ::
              {:ok, connection(), [response()]}
              | {:error, connection(), term(), [response()]}
              | :unknown

  @callback encode(websocket(), Mint.WebSocket.shorthand_frame() | Mint.WebSocket.frame()) ::
              {:ok, websocket(), binary()} | {:error, websocket(), term()}

  @callback decode(websocket(), binary()) ::
              {:ok, websocket(), [Mint.WebSocket.frame() | {:error, term()}]}
              | {:error, websocket(), term()}

  @callback stream_request_body(connection(), request_ref(), iodata()) ::
              {:ok, connection()} | {:error, connection(), term()}

  @callback close(connection()) :: term()
end
