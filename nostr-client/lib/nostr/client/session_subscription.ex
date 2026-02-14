defmodule Nostr.Client.SessionSubscription do
  @moduledoc """
  GenServer that owns one logical subscription across multiple relay sessions.

  Event notifications are emitted to the configured consumer as:

  - `{:nostr_session_subscription, sub_pid, {:event, relay_url, event}}`
  - `{:nostr_session_subscription, sub_pid, {:eose, relay_url}}`
  - `{:nostr_session_subscription, sub_pid, :eose_all}`
  - `{:nostr_session_subscription, sub_pid, {:closed, relay_url, message}}`
  - `{:nostr_session_subscription, sub_pid, {:error, relay_url, reason}}`

  ## Example

  ```elixir
  {:ok, sub_pid} =
    Nostr.Client.start_session_subscription(
      session_pid,
      [%Nostr.Filter{kinds: [1]}],
      consumer: self()
    )

  receive do
    {:nostr_session_subscription, ^sub_pid, {:event, relay_url, event}} ->
      {relay_url, event.id}
  end
  ```
  """

  use GenServer

  alias Nostr.Client.RelaySession
  alias Nostr.Client.Session

  @register_retry_ms 100

  defstruct session_pid: nil,
            session_monitor_ref: nil,
            logical_sub_id: nil,
            filters: [],
            consumer_pid: nil,
            relays: %{},
            sub_id_to_relay: %{},
            eose_all_sent?: false

  @type relay_state() :: %{
          relay_url: binary(),
          session_pid: pid(),
          relay_sub_id: binary(),
          mode: Session.relay_mode(),
          registered?: boolean(),
          eose?: boolean()
        }

  @type t() :: %__MODULE__{
          session_pid: pid(),
          session_monitor_ref: reference(),
          logical_sub_id: binary(),
          filters: [Nostr.Filter.t()],
          consumer_pid: pid(),
          relays: %{binary() => relay_state()},
          sub_id_to_relay: %{binary() => binary()},
          eose_all_sent?: boolean()
        }

  @type option() ::
          {:session, pid()}
          | {:filters, Nostr.Filter.t() | [Nostr.Filter.t()]}
          | {:consumer, pid()}
          | {:sub_id, binary()}

  @doc false
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc """
  Starts a logical multi-relay subscription process.

  ## Example

  ```elixir
  Nostr.Client.SessionSubscription.start_link(
    session: session_pid,
    filters: [%Nostr.Filter{kinds: [1]}],
    consumer: self()
  )
  ```
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stops the subscription process.

  ## Example

  ```elixir
  :ok = Nostr.Client.SessionSubscription.stop(sub_pid)
  ```
  """
  @spec stop(pid(), timeout()) :: :ok
  def stop(pid, timeout \\ 5_000) when is_pid(pid) and is_integer(timeout) do
    GenServer.stop(pid, :normal, timeout)
  end

  @doc """
  Returns internal subscription state.

  ## Example

  ```elixir
  %Nostr.Client.SessionSubscription{} =
    Nostr.Client.SessionSubscription.state(sub_pid)
  ```
  """
  @spec state(pid(), timeout()) :: t()
  def state(pid, timeout \\ 5_000) when is_pid(pid) and is_integer(timeout) do
    GenServer.call(pid, :state, timeout)
  end

  @impl true
  @spec init([option()]) :: {:ok, t(), {:continue, :subscribe}} | {:stop, term()}
  def init(opts) do
    with {:ok, session_pid} <- fetch_session_pid(opts),
         {:ok, filters} <- fetch_filters(opts),
         {:ok, consumer_pid} <- fetch_consumer_pid(opts) do
      logical_sub_id = Keyword.get_lazy(opts, :sub_id, &generate_sub_id/0)

      state = %__MODULE__{
        session_pid: session_pid,
        session_monitor_ref: Process.monitor(session_pid),
        logical_sub_id: logical_sub_id,
        filters: filters,
        consumer_pid: consumer_pid
      }

      {:ok, state, {:continue, :subscribe}}
    end
  end

  @impl true
  @spec handle_continue(:subscribe, t()) :: {:noreply, t()} | {:stop, term(), t()}
  def handle_continue(:subscribe, state) do
    case Session.register_subscription(state.session_pid, self()) do
      {:ok, relay_entries} ->
        next_state = register_all_relays(state, relay_entries)
        maybe_schedule_retry(next_state)
        {:noreply, maybe_notify_eose_all(next_state)}

      {:error, reason} ->
        send(
          state.consumer_pid,
          {:nostr_session_subscription, self(), {:error, :session, reason}}
        )

        {:stop, reason, state}
    end
  end

  @impl true
  @spec handle_call(:state, GenServer.from(), t()) :: {:reply, t(), t()}
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  @spec handle_info(term(), t()) :: {:noreply, t()} | {:stop, term(), t()}
  def handle_info(:register_retry, state) do
    next_state = register_unregistered_relays(state)
    maybe_schedule_retry(next_state)
    {:noreply, maybe_notify_eose_all(next_state)}
  end

  def handle_info({:nostr, :event, relay_sub_id, event}, state) do
    case Map.fetch(state.sub_id_to_relay, relay_sub_id) do
      {:ok, relay_url} ->
        send(
          state.consumer_pid,
          {:nostr_session_subscription, self(), {:event, relay_url, event}}
        )

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:nostr, :eose, relay_sub_id}, state) do
    case Map.fetch(state.sub_id_to_relay, relay_sub_id) do
      {:ok, relay_url} ->
        send(state.consumer_pid, {:nostr_session_subscription, self(), {:eose, relay_url}})
        next_state = mark_relay_eose(state, relay_url)
        {:noreply, maybe_notify_eose_all(next_state)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:nostr, :closed, relay_sub_id, message}, state) do
    case Map.fetch(state.sub_id_to_relay, relay_sub_id) do
      {:ok, relay_url} ->
        send(
          state.consumer_pid,
          {:nostr_session_subscription, self(), {:closed, relay_url, message}}
        )

        {:noreply, mark_relay_closed(state, relay_url)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:nostr_session, :relay_added, relay_url, relay_session_pid, mode}, state) do
    relay_entry = %{relay_url: relay_url, session_pid: relay_session_pid, mode: mode}
    next_state = add_relay_entry(state, relay_entry)
    next_state = register_relay_if_needed(next_state, relay_url)
    maybe_schedule_retry(next_state)
    {:noreply, next_state}
  end

  def handle_info({:nostr_session, :relay_removed, relay_url}, state) do
    {:noreply, remove_relay_entry(state, relay_url)}
  end

  def handle_info(
        {:nostr_session, :relay_mode_updated, relay_url, mode, relay_session_pid},
        state
      ) do
    relay_entry = %{relay_url: relay_url, session_pid: relay_session_pid, mode: mode}
    {:noreply, upsert_relay_mode(state, relay_entry)}
  end

  def handle_info({:nostr_session, :relay_error, relay_url, reason}, state) do
    send(state.consumer_pid, {:nostr_session_subscription, self(), {:error, relay_url, reason}})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{session_monitor_ref: ref} = state) do
    send(
      state.consumer_pid,
      {:nostr_session_subscription, self(), {:error, :session, {:session_down, reason}}}
    )

    {:stop, {:session_down, reason}, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  @spec terminate(term(), t()) :: :ok
  def terminate(_reason, state) do
    _ = Session.unregister_subscription(state.session_pid, self())

    Enum.each(state.relays, fn {_relay_url, relay_state} ->
      unregister_relay(relay_state)
    end)

    :ok
  end

  defp register_all_relays(state, relay_entries) do
    relay_entries
    |> Enum.reduce(state, fn relay_entry, acc -> add_relay_entry(acc, relay_entry) end)
    |> register_unregistered_relays()
  end

  defp register_unregistered_relays(state) do
    Enum.reduce(state.relays, state, fn {relay_url, relay_state}, acc ->
      if relay_state.registered? do
        acc
      else
        register_relay_if_needed(acc, relay_url)
      end
    end)
  end

  defp register_relay_if_needed(state, relay_url) do
    case Map.fetch(state.relays, relay_url) do
      :error ->
        state

      {:ok, relay_state} ->
        case RelaySession.register_subscription(
               relay_state.session_pid,
               relay_state.relay_sub_id,
               self(),
               state.filters
             ) do
          :ok ->
            put_relay_state(state, relay_url, %{relay_state | registered?: true})

          {:error, :not_connected} ->
            state

          {:error, reason} ->
            send(
              state.consumer_pid,
              {:nostr_session_subscription, self(), {:error, relay_url, reason}}
            )

            state
        end
    end
  end

  defp unregister_relay(relay_state) do
    try do
      :ok =
        RelaySession.unregister_subscription(
          relay_state.session_pid,
          relay_state.relay_sub_id,
          self()
        )
    catch
      :exit, _reason -> :ok
    end
  end

  defp maybe_schedule_retry(state) do
    if Enum.any?(state.relays, fn {_relay_url, relay_state} -> not relay_state.registered? end) do
      Process.send_after(self(), :register_retry, @register_retry_ms)
    end
  end

  defp add_relay_entry(state, %{relay_url: relay_url, session_pid: session_pid, mode: mode}) do
    case Map.fetch(state.relays, relay_url) do
      {:ok, relay_state} ->
        next_state = %{relay_state | session_pid: session_pid, mode: mode}
        put_relay_state(state, relay_url, next_state)

      :error ->
        relay_sub_id = generate_relay_sub_id(state.logical_sub_id, relay_url)

        relay_state = %{
          relay_url: relay_url,
          session_pid: session_pid,
          relay_sub_id: relay_sub_id,
          mode: mode,
          registered?: false,
          eose?: false
        }

        put_relay_state(state, relay_url, relay_state)
    end
  end

  defp remove_relay_entry(state, relay_url) do
    case Map.pop(state.relays, relay_url) do
      {nil, _relays} ->
        state

      {relay_state, relays} ->
        unregister_relay(relay_state)

        %{
          state
          | relays: relays,
            sub_id_to_relay: Map.delete(state.sub_id_to_relay, relay_state.relay_sub_id)
        }
    end
  end

  defp upsert_relay_mode(state, %{relay_url: relay_url, mode: mode, session_pid: session_pid}) do
    case Map.fetch(state.relays, relay_url) do
      :error ->
        add_relay_entry(state, %{relay_url: relay_url, mode: mode, session_pid: session_pid})

      {:ok, relay_state} ->
        put_relay_state(state, relay_url, %{relay_state | mode: mode, session_pid: session_pid})
    end
  end

  defp put_relay_state(state, relay_url, relay_state) do
    %{
      state
      | relays: Map.put(state.relays, relay_url, relay_state),
        sub_id_to_relay: Map.put(state.sub_id_to_relay, relay_state.relay_sub_id, relay_url)
    }
  end

  defp mark_relay_eose(state, relay_url) do
    case Map.fetch(state.relays, relay_url) do
      {:ok, relay_state} -> put_relay_state(state, relay_url, %{relay_state | eose?: true})
      :error -> state
    end
  end

  defp mark_relay_closed(state, relay_url) do
    case Map.fetch(state.relays, relay_url) do
      {:ok, relay_state} -> put_relay_state(state, relay_url, %{relay_state | registered?: false})
      :error -> state
    end
  end

  defp maybe_notify_eose_all(%{eose_all_sent?: true} = state), do: state

  defp maybe_notify_eose_all(state) do
    cond do
      map_size(state.relays) == 0 ->
        state

      Enum.all?(state.relays, fn {_relay_url, relay_state} -> relay_state.eose? end) ->
        send(state.consumer_pid, {:nostr_session_subscription, self(), :eose_all})
        %{state | eose_all_sent?: true}

      true ->
        state
    end
  end

  defp fetch_session_pid(opts) do
    case Keyword.fetch(opts, :session) do
      {:ok, session_pid} when is_pid(session_pid) -> {:ok, session_pid}
      {:ok, _session_pid} -> {:error, {:invalid_option, :session}}
      :error -> {:error, {:missing_option, :session}}
    end
  end

  defp fetch_filters(opts) do
    case Keyword.fetch(opts, :filters) do
      {:ok, %Nostr.Filter{} = filter} -> {:ok, [filter]}
      {:ok, filters} when is_list(filters) -> {:ok, filters}
      {:ok, _filters} -> {:error, {:invalid_option, :filters}}
      :error -> {:error, {:missing_option, :filters}}
    end
  end

  defp fetch_consumer_pid(opts) do
    case Keyword.get(opts, :consumer, self()) do
      consumer_pid when is_pid(consumer_pid) -> {:ok, consumer_pid}
      _consumer_pid -> {:error, {:invalid_option, :consumer}}
    end
  end

  defp generate_sub_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp generate_relay_sub_id(logical_sub_id, relay_url) do
    suffix =
      relay_url
      |> :erlang.phash2(16_777_216)
      |> Integer.to_string(16)
      |> String.pad_leading(6, "0")

    candidate = "#{logical_sub_id}-#{suffix}"

    if byte_size(candidate) <= 64 do
      candidate
    else
      String.slice(candidate, 0, 64)
    end
  end
end
