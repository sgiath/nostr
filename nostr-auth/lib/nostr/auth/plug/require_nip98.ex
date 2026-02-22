defmodule Nostr.Auth.Plug.RequireNip98 do
  @moduledoc """
  Ready-to-use Plug for enforcing NIP-98 HTTP authorization.

  On success, assigns the verified event to `conn.assigns`.
  On failure, returns a halted 401 response by default.

  ## Options

  - `:assign` - assign key for the validated event (default: `:nostr_event`)
  - `:request_context` - static map or function to build request context
  - `:request_context_opts` - options passed to `Nostr.Auth.Plug.request_context/2`
  - `:read_body` - `true` or keyword options for `Plug.Conn.read_body/2`
  - `:body_assign` - assign key for raw body when `:read_body` is used
  - `:nip98` - options forwarded to `Nostr.NIP98.validate_request/3`
  - `:replay` - replay adapter tuple (`{module, opts}`)
  - `:error_status` - status for default error handler (default: `401`)
  - `:on_error` - custom `(conn, reason) -> conn` error handler
  """

  @behaviour Plug

  alias Nostr.Auth.Plug, as: AuthPlug
  alias Plug.Conn

  @type init_opts() :: keyword()
  @type plugin_opts() :: %{
          assign: atom(),
          request_context:
            nil | map() | (Conn.t() -> map() | {:ok, map()} | {:ok, map(), Conn.t()}),
          request_context_opts: keyword(),
          read_body: false | true | keyword(),
          body_assign: nil | atom(),
          nip98: keyword(),
          replay: nil | {module(), keyword()},
          error_status: pos_integer(),
          on_error: nil | (Conn.t(), term() -> Conn.t())
        }

  @doc """
  Initializes plug options.
  """
  @impl true
  @spec init(init_opts()) :: plugin_opts()
  def init(opts) do
    %{
      assign: Keyword.get(opts, :assign, :nostr_event),
      request_context: Keyword.get(opts, :request_context),
      request_context_opts: Keyword.get(opts, :request_context_opts, []),
      read_body: Keyword.get(opts, :read_body, false),
      body_assign: Keyword.get(opts, :body_assign),
      nip98: Keyword.get(opts, :nip98, []),
      replay: Keyword.get(opts, :replay),
      error_status: Keyword.get(opts, :error_status, 401),
      on_error: Keyword.get(opts, :on_error)
    }
  end

  @doc """
  Validates NIP-98 auth and assigns the verified event.
  """
  @impl true
  @spec call(Conn.t(), plugin_opts()) :: Conn.t()
  def call(%Conn{} = conn, opts) do
    with {:ok, conn, context} <- build_context(conn, opts),
         {:ok, event} <-
           AuthPlug.validate_conn(conn,
             request_context: context,
             nip98: opts.nip98,
             replay: opts.replay
           ) do
      Conn.assign(conn, opts.assign, event)
    else
      {:error, reason, %Conn{} = conn} -> handle_error(conn, reason, opts)
      {:error, reason} -> handle_error(conn, reason, opts)
    end
  end

  defp build_context(%Conn{} = conn, %{request_context: context}) when is_map(context) do
    {:ok, conn, context}
  end

  defp build_context(%Conn{} = conn, %{request_context: context_fun})
       when is_function(context_fun, 1) do
    case context_fun.(conn) do
      context when is_map(context) ->
        {:ok, conn, context}

      {:ok, context} when is_map(context) ->
        {:ok, conn, context}

      {:ok, context, %Conn{} = updated_conn} when is_map(context) ->
        {:ok, updated_conn, context}

      {:error, reason} ->
        {:error, {:request_context, reason}, conn}

      {:error, reason, %Conn{} = updated_conn} ->
        {:error, {:request_context, reason}, updated_conn}

      _other ->
        {:error, :invalid_request_context, conn}
    end
  end

  defp build_context(%Conn{} = conn, opts) do
    with {:ok, conn, request_context_opts} <- maybe_attach_body(conn, opts) do
      {:ok, conn, AuthPlug.request_context(conn, request_context_opts)}
    end
  end

  defp maybe_attach_body(%Conn{} = conn, %{read_body: false, request_context_opts: context_opts}) do
    {:ok, conn, context_opts}
  end

  defp maybe_attach_body(
         %Conn{} = conn,
         %{read_body: read_body, request_context_opts: context_opts} = opts
       ) do
    read_body_opts = if read_body == true, do: [], else: read_body

    case Conn.read_body(conn, read_body_opts) do
      {:ok, body, %Conn{} = updated_conn} ->
        updated_conn = maybe_assign_body(updated_conn, opts.body_assign, body)
        {:ok, updated_conn, Keyword.put_new(context_opts, :body, body)}

      {:more, _partial_body, %Conn{} = updated_conn} ->
        {:error, {:read_body, :too_large}, updated_conn}

      {:error, reason} ->
        {:error, {:read_body, reason}, conn}
    end
  end

  defp maybe_assign_body(%Conn{} = conn, nil, _body), do: conn

  defp maybe_assign_body(%Conn{} = conn, assign_key, body),
    do: Conn.assign(conn, assign_key, body)

  defp handle_error(%Conn{} = conn, reason, %{on_error: on_error})
       when is_function(on_error, 2) do
    on_error.(conn, reason)
  end

  defp handle_error(%Conn{} = conn, reason, %{error_status: status}) do
    default_on_error(conn, reason, status)
  end

  defp default_on_error(%Conn{} = conn, reason, status) do
    body = "unauthorized: #{inspect(reason)}"

    conn
    |> Conn.put_resp_content_type("text/plain")
    |> Conn.send_resp(status, body)
    |> Conn.halt()
  end
end
