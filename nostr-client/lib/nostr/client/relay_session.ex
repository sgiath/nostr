defmodule Nostr.Client.RelaySession do
  @moduledoc """
  GenServer that owns one WebSocket session to one relay for one pubkey owner.

  The session stores only `pubkey` and signer module reference. Secret key
  material must stay outside the session process.

  ## Example

  ```elixir
  {:ok, session_pid} =
    Nostr.Client.RelaySession.start_link(
      relay_url: "wss://relay.example",
      pubkey: pubkey,
      signer: signer
    )

  :connected = Nostr.Client.RelaySession.status(session_pid)
  :ok = Nostr.Client.RelaySession.publish(session_pid, event)
  ```
  """

  use GenServer

  alias Nostr.Client.SessionKey
  alias Nostr.Client.Transport.Mint

  @type phase() :: :disconnected | :upgrading | :connected | :closing

  defstruct relay_url: nil,
            pubkey: nil,
            signer: nil,
            session_key: nil,
            host: nil,
            port: nil,
            path: nil,
            http_scheme: nil,
            ws_scheme: nil,
            conn: nil,
            websocket: nil,
            ref: nil,
            phase: :disconnected,
            upgrade_status: nil,
            upgrade_headers: nil,
            upgrade_done?: false,
            auth_state: :unauthenticated,
            auth_challenge: nil,
            pending_auth_event_id: nil,
            pending_auth_retry_publish_id: nil,
            subscriptions: %{},
            pending_publishes: %{},
            pending_counts: %{},
            notify_pid: nil,
            transport: Mint,
            transport_opts: []

  @doc false
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc """
  Starts a relay session process.

  ## Example

  ```elixir
  Nostr.Client.RelaySession.start_link(
    relay_url: relay_url,
    pubkey: pubkey,
    signer: signer
  )
  ```
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc """
  Returns current connection phase.

  ## Example

  ```elixir
  :connected = Nostr.Client.RelaySession.status(session_pid)
  ```
  """
  @spec status(pid(), timeout()) :: phase()
  def status(pid, timeout \\ 5_000), do: GenServer.call(pid, :status, timeout)

  @doc """
  Publishes an event and waits for relay `OK`.

  ## Example

  ```elixir
  :ok = Nostr.Client.RelaySession.publish(session_pid, event)
  ```
  """
  @spec publish(pid(), Nostr.Event.t(), timeout()) :: :ok | {:error, term()}
  def publish(pid, event, timeout \\ 5_000) do
    GenServer.call(pid, {:publish, event}, timeout)
  end

  @doc """
  Sends a `COUNT` request and waits for relay response.

  ## Example

  ```elixir
  {:ok, %{count: count}} =
    Nostr.Client.RelaySession.count(session_pid, [%Nostr.Filter{kinds: [1]}])
  ```
  """
  @spec count(pid(), Nostr.Filter.t() | [Nostr.Filter.t()], timeout()) ::
          {:ok, Nostr.Message.count_payload()} | {:error, term()}
  def count(pid, filters, timeout \\ 5_000) do
    GenServer.call(pid, {:count, filters}, timeout)
  end

  @doc """
  Registers subscriber PID for `sub_id` and sends `REQ`.

  ## Example

  ```elixir
  :ok =
    Nostr.Client.RelaySession.register_subscription(
      session_pid,
      "sub-1",
      self(),
      [%Nostr.Filter{kinds: [1]}]
    )
  ```
  """
  @spec register_subscription(
          pid(),
          binary(),
          pid(),
          Nostr.Filter.t() | [Nostr.Filter.t()],
          timeout()
        ) ::
          :ok | {:error, term()}
  def register_subscription(pid, sub_id, subscriber_pid, filters, timeout \\ 5_000) do
    GenServer.call(pid, {:register_subscription, sub_id, subscriber_pid, filters}, timeout)
  end

  @doc """
  Unregisters subscriber and sends `CLOSE`.

  ## Example

  ```elixir
  :ok = Nostr.Client.RelaySession.unregister_subscription(session_pid, "sub-1", self())
  ```
  """
  @spec unregister_subscription(pid(), binary(), pid(), timeout()) :: :ok
  def unregister_subscription(pid, sub_id, subscriber_pid, timeout \\ 5_000) do
    GenServer.call(pid, {:unregister_subscription, sub_id, subscriber_pid}, timeout)
  end

  @doc """
  Gracefully closes the relay session process.

  ## Example

  ```elixir
  :ok = Nostr.Client.RelaySession.close(session_pid)
  ```
  """
  @spec close(pid(), timeout()) :: :ok
  def close(pid, timeout \\ 5_000), do: GenServer.call(pid, :close, timeout)

  @impl true
  def init(opts) do
    with {:ok, relay_url} <- fetch_binary_opt(opts, :relay_url),
         {:ok, pubkey} <- fetch_binary_opt(opts, :pubkey),
         {:ok, signer} <- fetch_atom_opt(opts, :signer),
         {:ok, transport} <- fetch_atom_opt(opts, :transport, Mint),
         {:ok, transport_opts} <- fetch_list_opt(opts, :transport_opts, []),
         {:ok, parsed} <- parse_relay_url(relay_url) do
      state = %__MODULE__{
        relay_url: relay_url,
        pubkey: pubkey,
        signer: signer,
        session_key: Keyword.get(opts, :session_key),
        host: parsed.host,
        port: parsed.port,
        path: parsed.path,
        http_scheme: parsed.http_scheme,
        ws_scheme: parsed.ws_scheme,
        notify_pid: Keyword.get(opts, :notify),
        transport: transport,
        transport_opts: transport_opts
      }

      {:ok, state, {:continue, :connect}}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    notify(state, {:nostr_client, :connecting, self(), state.relay_url})
    connect_opts = Keyword.put_new(state.transport_opts, :protocols, [:http1])

    with {:ok, conn} <-
           state.transport.connect(state.http_scheme, state.host, state.port, connect_opts),
         {:ok, conn, request_ref} <-
           state.transport.upgrade(state.ws_scheme, conn, state.path, [], []) do
      {:noreply, %{state | conn: conn, ref: request_ref, phase: :upgrading}}
    else
      {:error, conn, reason} -> {:stop, {:connect_error, reason}, %{state | conn: conn}}
      {:error, reason} -> {:stop, {:connect_error, reason}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.phase, state}

  def handle_call({:publish, _event}, _from, %{phase: phase} = state) when phase != :connected do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:count, _filters}, _from, %{phase: phase} = state) when phase != :connected do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:publish, %Nostr.Event{} = event}, from, state) do
    with {:ok, event_id} <- fetch_event_id(event),
         false <- Map.has_key?(state.pending_publishes, event_id),
         {:ok, next_state} <- send_nostr_message(state, Nostr.Message.create_event(event)) do
      pending =
        Map.put(next_state.pending_publishes, event_id, %{
          from: from,
          event: event,
          retried?: false
        })

      {:noreply, %{next_state | pending_publishes: pending}}
    else
      true -> {:reply, {:error, :publish_already_pending}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:count, filters}, from, state) do
    with {:ok, normalized_filters} <- normalize_count_filters(filters),
         query_id <- generate_query_id(),
         {:ok, next_state} <-
           send_nostr_message(state, Nostr.Message.count(normalized_filters, query_id)) do
      pending_counts = Map.put(next_state.pending_counts, query_id, from)
      {:noreply, %{next_state | pending_counts: pending_counts}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:register_subscription, _sub_id, _subscriber_pid, _filters},
        _from,
        %{phase: phase} = state
      )
      when phase != :connected do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:register_subscription, sub_id, subscriber_pid, filters}, _from, state) do
    case Map.fetch(state.subscriptions, sub_id) do
      {:ok, ^subscriber_pid} ->
        {:reply, :ok, state}

      {:ok, _other} ->
        {:reply, {:error, :sub_id_taken}, state}

      :error ->
        case send_nostr_message(state, Nostr.Message.request(filters, sub_id)) do
          {:ok, next_state} ->
            {:reply, :ok,
             %{
               next_state
               | subscriptions: Map.put(next_state.subscriptions, sub_id, subscriber_pid)
             }}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:unregister_subscription, sub_id, subscriber_pid}, _from, state) do
    {entry, subscriptions} = Map.pop(state.subscriptions, sub_id)

    next_state =
      if entry == subscriber_pid do
        case send_nostr_message(
               %{state | subscriptions: subscriptions},
               Nostr.Message.close(sub_id)
             ) do
          {:ok, updated} -> updated
          {:error, _reason} -> %{state | subscriptions: subscriptions}
        end
      else
        state
      end

    {:reply, :ok, next_state}
  end

  def handle_call(:close, _from, state) do
    state = %{state | phase: :closing}
    _ = send_frame(state, :close)
    {:stop, :normal, :ok, close_transport(state)}
  end

  @impl true
  def handle_info(_message, %{conn: nil} = state), do: {:noreply, state}

  def handle_info(message, state) do
    case state.transport.stream(state.conn, message) do
      :unknown ->
        {:noreply, state}

      {:ok, conn, responses} ->
        process_responses(%{state | conn: conn}, responses)

      {:error, conn, reason, responses} ->
        case process_responses(%{state | conn: conn}, responses) do
          {:stop, stop_reason, next_state} -> {:stop, stop_reason, next_state}
          {:noreply, next_state} -> {:stop, {:transport_error, reason}, next_state}
        end
    end
  end

  @impl true
  def terminate(reason, state) do
    _ = close_transport(state)
    fail_pending_publishes(state, {:session_stopped, normalize_reason(reason)})
    fail_pending_counts(state, {:session_stopped, normalize_reason(reason)})
    notify_subscriptions(state, {:nostr, :error, {:session_stopped, normalize_reason(reason)}})
    notify(state, {:nostr_client, :disconnected, self(), normalize_reason(reason)})
    :ok
  end

  defp process_responses(state, responses) do
    Enum.reduce_while(responses, {:noreply, state}, fn response, {:noreply, acc} ->
      case handle_response(acc, response) do
        {:noreply, next} -> {:cont, {:noreply, next}}
        {:stop, reason, next} -> {:halt, {:stop, reason, next}}
      end
    end)
  end

  defp handle_response(%{phase: :upgrading, ref: ref} = state, {:status, ref, status}) do
    {:noreply, %{state | upgrade_status: status}}
  end

  defp handle_response(%{phase: :upgrading, ref: ref} = state, {:headers, ref, headers}) do
    {:noreply, %{state | upgrade_headers: headers}}
  end

  defp handle_response(%{phase: :upgrading, ref: ref} = state, {:done, ref}) do
    state = %{state | upgrade_done?: true}

    if is_integer(state.upgrade_status) and is_list(state.upgrade_headers) do
      case state.transport.new(state.conn, state.ref, state.upgrade_status, state.upgrade_headers,
             mode: :active
           ) do
        {:ok, conn, websocket} ->
          next_state = %{
            state
            | conn: conn,
              websocket: websocket,
              phase: :connected,
              upgrade_done?: false,
              upgrade_status: nil,
              upgrade_headers: nil
          }

          notify(next_state, {:nostr_client, :connected, self(), next_state.relay_url})
          {:noreply, next_state}

        {:error, conn, reason} ->
          {:stop, {:upgrade_error, reason}, %{state | conn: conn}}
      end
    else
      {:noreply, state}
    end
  end

  defp handle_response(%{phase: phase, ref: ref} = state, {:data, ref, data})
       when phase in [:connected, :closing] do
    case state.transport.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        process_frames(%{state | websocket: websocket}, frames)

      {:error, websocket, reason} ->
        {:stop, {:decode_error, reason}, %{state | websocket: websocket}}
    end
  end

  defp handle_response(%{ref: ref} = state, {:error, ref, reason}),
    do: {:stop, {:stream_error, reason}, state}

  defp handle_response(state, _response), do: {:noreply, state}

  defp process_frames(state, frames) do
    Enum.reduce_while(frames, {:noreply, state}, fn frame, {:noreply, acc} ->
      case handle_frame(acc, frame) do
        {:noreply, next} -> {:cont, {:noreply, next}}
        {:stop, reason, next} -> {:halt, {:stop, reason, next}}
      end
    end)
  end

  defp handle_frame(state, {:ping, payload}) do
    case send_frame(state, {:pong, payload}) do
      {:ok, next} -> {:noreply, next}
      {:error, reason, next} -> {:stop, reason, next}
    end
  end

  defp handle_frame(state, {:close, code, reason}) do
    _ = send_frame(%{state | phase: :closing}, :close)
    {:stop, {:remote_close, code, reason}, close_transport(%{state | phase: :closing})}
  end

  defp handle_frame(state, {:text, payload}) when is_binary(payload),
    do: handle_text_payload(state, payload)

  defp handle_frame(state, {:error, reason}), do: {:stop, {:frame_error, reason}, state}
  defp handle_frame(state, _frame), do: {:noreply, state}

  defp handle_text_payload(state, payload) do
    case parse_message(payload) do
      {:event, sub_id, %Nostr.Event{} = event} ->
        dispatch_subscription(state, sub_id, {:nostr, :event, sub_id, event})

      {:eose, sub_id} ->
        dispatch_subscription(state, sub_id, {:nostr, :eose, sub_id})

      {:count, query_id, payload} ->
        handle_count_response(state, query_id, payload)

      {:closed, sub_id, message} ->
        handle_closed_response(state, sub_id, message)

      {:ok, event_id, accepted?, message} ->
        handle_ok(state, event_id, accepted?, message)

      {:auth, challenge} when is_binary(challenge) ->
        handle_auth_challenge(state, challenge)

      {:notice, message} ->
        notify(state, {:nostr_client, :notice, self(), message})
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  defp parse_message(payload) do
    try do
      Nostr.Message.parse(payload)
    rescue
      _error -> :error
    end
  end

  defp handle_ok(state, event_id, accepted?, message)
       when is_binary(event_id) and is_boolean(accepted?) and is_binary(message) do
    cond do
      event_id == state.pending_auth_event_id -> handle_auth_ok(state, accepted?, message)
      accepted? -> publish_ok(state, event_id)
      true -> publish_rejected(state, event_id, message)
    end
  end

  defp handle_ok(state, _event_id, _accepted?, _message), do: {:noreply, state}

  defp publish_ok(state, event_id) do
    case Map.pop(state.pending_publishes, event_id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from}, pending} ->
        GenServer.reply(from, :ok)
        {:noreply, %{state | pending_publishes: pending}}
    end
  end

  defp publish_rejected(state, event_id, message) do
    case Map.fetch(state.pending_publishes, event_id) do
      :error ->
        {:noreply, state}

      {:ok, publish_state} ->
        maybe_retry_rejected_publish(state, event_id, publish_state, message)
    end
  end

  defp maybe_retry_rejected_publish(state, event_id, publish_state, message) do
    if retry_auth?(state, publish_state, message) do
      pending = Map.put(state.pending_publishes, event_id, %{publish_state | retried?: true})
      maybe_start_auth_for_retry(%{state | pending_publishes: pending}, event_id)
    else
      fail_pending_publish(state, event_id, {:publish_rejected, message})
    end
  end

  defp maybe_start_auth_for_retry(state, event_id) do
    case start_auth(state, event_id) do
      {:ok, next_state} -> {:noreply, next_state}
      {:error, reason, next_state} -> fail_pending_publish(next_state, event_id, reason)
    end
  end

  defp retry_auth?(state, publish_state, message) do
    not publish_state.retried? and state.auth_state != :authenticated and
      String.starts_with?(message, "restricted") and
      message
      |> String.downcase()
      |> String.contains?("auth")
  end

  defp handle_auth_challenge(state, challenge) do
    case start_auth(%{state | auth_challenge: challenge}, state.pending_auth_retry_publish_id) do
      {:ok, next_state} -> {:noreply, next_state}
      {:error, _reason, next_state} -> {:noreply, next_state}
    end
  end

  defp start_auth(%{auth_state: :authenticating} = state, _retry_event_id), do: {:ok, state}

  defp start_auth(state, retry_event_id) do
    with challenge when is_binary(challenge) <- state.auth_challenge,
         true <- function_exported?(state.signer, :sign_client_auth, 3),
         {:ok, %Nostr.Event{} = auth_event} <-
           state.signer.sign_client_auth(state.pubkey, state.relay_url, challenge),
         {:ok, auth_event_id} <- fetch_event_id(auth_event),
         {:ok, next_state} <- send_nostr_message(state, Nostr.Message.auth(auth_event)) do
      {:ok,
       %{
         next_state
         | auth_state: :authenticating,
           pending_auth_event_id: auth_event_id,
           pending_auth_retry_publish_id: retry_event_id
       }}
    else
      false -> {:error, {:invalid_signer, state.signer}, state}
      nil -> {:error, :auth_required, state}
      {:error, reason} -> {:error, {:auth_failed, reason}, state}
      other -> {:error, {:auth_failed, other}, state}
    end
  end

  defp handle_auth_ok(state, true, _message) do
    state = %{state | auth_state: :authenticated, pending_auth_event_id: nil}

    case state.pending_auth_retry_publish_id do
      nil ->
        {:noreply, state}

      event_id ->
        retry_pending_publish_after_auth(state, event_id)
    end
  end

  defp handle_auth_ok(state, false, message) do
    state = %{state | auth_state: :unauthenticated, pending_auth_event_id: nil}

    case state.pending_auth_retry_publish_id do
      nil ->
        {:noreply, state}

      event_id ->
        fail_pending_publish(
          %{state | pending_auth_retry_publish_id: nil},
          event_id,
          {:auth_failed, message}
        )
    end
  end

  defp retry_pending_publish_after_auth(state, event_id) do
    case Map.fetch(state.pending_publishes, event_id) do
      :error ->
        {:noreply, %{state | pending_auth_retry_publish_id: nil}}

      {:ok, %{event: event}} ->
        resend_pending_publish_after_auth(state, event_id, event)
    end
  end

  defp resend_pending_publish_after_auth(state, event_id, event) do
    state_with_cleared_retry = %{state | pending_auth_retry_publish_id: nil}

    case send_nostr_message(state_with_cleared_retry, Nostr.Message.create_event(event)) do
      {:ok, next_state} -> {:noreply, next_state}
      {:error, reason} -> fail_pending_publish(state_with_cleared_retry, event_id, reason)
    end
  end

  defp fail_pending_publish(state, event_id, reason) do
    case Map.pop(state.pending_publishes, event_id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, reason})
        {:noreply, %{state | pending_publishes: pending}}
    end
  end

  defp fail_pending_publishes(state, reason) do
    Enum.each(state.pending_publishes, fn {_event_id, %{from: from}} ->
      GenServer.reply(from, {:error, reason})
    end)
  end

  defp fail_pending_counts(state, reason) do
    Enum.each(state.pending_counts, fn {_query_id, from} ->
      GenServer.reply(from, {:error, reason})
    end)
  end

  defp handle_count_response(state, query_id, payload) do
    case Map.pop(state.pending_counts, query_id) do
      {nil, _pending_counts} ->
        {:noreply, state}

      {from, pending_counts} ->
        GenServer.reply(from, {:ok, payload})
        {:noreply, %{state | pending_counts: pending_counts}}
    end
  end

  defp handle_closed_response(state, sub_id, message) do
    case Map.pop(state.pending_counts, sub_id) do
      {nil, _pending_counts} ->
        state = send_to_subscription(state, sub_id, {:nostr, :closed, sub_id, message})
        {:noreply, %{state | subscriptions: Map.delete(state.subscriptions, sub_id)}}

      {from, pending_counts} ->
        GenServer.reply(from, {:error, {:closed, message}})
        {:noreply, %{state | pending_counts: pending_counts}}
    end
  end

  defp dispatch_subscription(state, sub_id, message),
    do: {:noreply, send_to_subscription(state, sub_id, message)}

  defp send_to_subscription(state, sub_id, message) do
    case Map.fetch(state.subscriptions, sub_id) do
      {:ok, pid} when is_pid(pid) -> send(pid, message)
      _not_found -> :ok
    end

    state
  end

  defp notify_subscriptions(state, message) do
    Enum.each(state.subscriptions, fn {_sub_id, pid} -> send(pid, message) end)
  end

  defp send_nostr_message(state, message) do
    payload = Nostr.Message.serialize(message)

    if state.phase == :connected do
      case send_frame(state, {:text, payload}) do
        {:ok, next_state} -> {:ok, next_state}
        {:error, reason, _next_state} -> {:error, reason}
      end
    else
      {:error, :not_connected}
    end
  end

  defp send_frame(%{conn: nil} = state, _frame), do: {:error, :not_connected, state}
  defp send_frame(%{websocket: nil} = state, _frame), do: {:error, :not_connected, state}
  defp send_frame(%{ref: nil} = state, _frame), do: {:error, :not_connected, state}

  defp send_frame(state, frame) do
    with {:ok, websocket, encoded} <- state.transport.encode(state.websocket, frame),
         {:ok, conn} <- state.transport.stream_request_body(state.conn, state.ref, encoded) do
      {:ok, %{state | conn: conn, websocket: websocket}}
    else
      {:error, _ctx, reason} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, state}
      _other -> {:error, :send_failed, state}
    end
  end

  defp close_transport(%{conn: nil} = state), do: state

  defp close_transport(state) do
    _ = state.transport.close(state.conn)
    %{state | conn: nil}
  end

  defp fetch_event_id(%Nostr.Event{id: id}) when is_binary(id), do: {:ok, id}
  defp fetch_event_id(_event), do: {:error, :invalid_event}

  defp notify(%{notify_pid: pid}, message) when is_pid(pid), do: send(pid, message)
  defp notify(_state, _message), do: :ok

  defp normalize_reason(:normal), do: :normal
  defp normalize_reason(:shutdown), do: :shutdown
  defp normalize_reason({:shutdown, reason}), do: reason
  defp normalize_reason(reason), do: reason

  defp parse_relay_url(relay_url) do
    uri = URI.parse(relay_url)

    with {:ok, normalized_url} <- SessionKey.normalize_relay_url(relay_url),
         %URI{host: host, scheme: scheme, port: port, path: path, query: query} =
           URI.parse(normalized_url),
         true <- is_binary(host),
         true <- scheme in ["ws", "wss"] do
      ws_scheme = if scheme == "ws", do: :ws, else: :wss
      http_scheme = if scheme == "ws", do: :http, else: :https
      final_path = if is_binary(path) and path != "", do: path, else: "/"
      final_path = if is_binary(query), do: final_path <> "?" <> query, else: final_path

      {:ok,
       %{
         host: host,
         port: port || default_port(uri),
         path: final_path,
         ws_scheme: ws_scheme,
         http_scheme: http_scheme
       }}
    else
      _other -> {:error, :invalid_relay_url}
    end
  end

  defp default_port(%URI{scheme: "ws"}), do: 80
  defp default_port(%URI{scheme: "wss"}), do: 443

  defp fetch_binary_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp fetch_atom_opt(opts, key, default \\ nil) do
    value =
      if default == nil,
        do: Keyword.get(opts, key, :missing),
        else: Keyword.get(opts, key, default)

    cond do
      value == :missing -> {:error, {:missing_option, key}}
      is_atom(value) -> {:ok, value}
      true -> {:error, {:invalid_option, key}}
    end
  end

  defp fetch_list_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_list(value) -> {:ok, value}
      _value -> {:error, {:invalid_option, key}}
    end
  end

  defp normalize_count_filters(%Nostr.Filter{} = filter), do: {:ok, [filter]}

  defp normalize_count_filters(filters) when is_list(filters) and filters != [] do
    if Enum.all?(filters, &match?(%Nostr.Filter{}, &1)) do
      {:ok, filters}
    else
      {:error, :invalid_filters}
    end
  end

  defp normalize_count_filters(_filters), do: {:error, :invalid_filters}

  defp generate_query_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
