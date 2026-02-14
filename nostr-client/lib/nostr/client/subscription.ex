defmodule Nostr.Client.Subscription do
  @moduledoc """
  GenServer that owns one NIP-01 subscription on top of a RelaySession.

  Events are forwarded to the configured consumer as:

  - `{:nostr_subscription, sub_pid, {:event, event}}`
  - `{:nostr_subscription, sub_pid, :eose}`
  - `{:nostr_subscription, sub_pid, {:closed, message}}`
  - `{:nostr_subscription, sub_pid, {:error, reason}}`

  ## Example

  ```elixir
  {:ok, sub_pid} =
    Nostr.Client.Subscription.start_link(
      session: session_pid,
      filters: [%Nostr.Filter{kinds: [1]}],
      consumer: self()
    )

  receive do
    {:nostr_subscription, ^sub_pid, {:event, event}} -> event.id
  end
  ```
  """

  use GenServer

  alias Nostr.Client.RelaySession

  @register_retry_ms 100

  defstruct session_pid: nil,
            session_monitor_ref: nil,
            sub_id: nil,
            filters: [],
            consumer_pid: nil,
            registered?: false,
            eose?: false,
            closed_reason: nil

  @type t() :: %__MODULE__{
          session_pid: pid(),
          session_monitor_ref: reference(),
          sub_id: binary(),
          filters: [Nostr.Filter.t()],
          consumer_pid: pid(),
          registered?: boolean(),
          eose?: boolean(),
          closed_reason: binary() | nil
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
  Starts a subscription process.

  ## Example

  ```elixir
  Nostr.Client.Subscription.start_link(
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
  :ok = Nostr.Client.Subscription.stop(sub_pid)
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
  %Nostr.Client.Subscription{} = Nostr.Client.Subscription.state(sub_pid)
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
      sub_id = Keyword.get_lazy(opts, :sub_id, &generate_sub_id/0)

      state = %__MODULE__{
        session_pid: session_pid,
        session_monitor_ref: Process.monitor(session_pid),
        sub_id: sub_id,
        filters: filters,
        consumer_pid: consumer_pid
      }

      {:ok, state, {:continue, :subscribe}}
    end
  end

  @impl true
  @spec handle_continue(:subscribe, t()) :: {:noreply, t()} | {:stop, term(), t()}
  def handle_continue(:subscribe, state) do
    case register_with_session(state) do
      {:ok, next_state} -> {:noreply, next_state}
      {:retry, next_state} -> {:noreply, next_state}
      {:error, reason, next_state} -> {:stop, reason, next_state}
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
    case register_with_session(state) do
      {:ok, next_state} -> {:noreply, next_state}
      {:retry, next_state} -> {:noreply, next_state}
      {:error, reason, next_state} -> {:stop, reason, next_state}
    end
  end

  def handle_info({:nostr, :event, sub_id, event}, %{sub_id: sub_id} = state) do
    send(state.consumer_pid, {:nostr_subscription, self(), {:event, event}})
    {:noreply, state}
  end

  def handle_info({:nostr, :eose, sub_id}, %{sub_id: sub_id} = state) do
    send(state.consumer_pid, {:nostr_subscription, self(), :eose})
    {:noreply, %{state | eose?: true}}
  end

  def handle_info({:nostr, :closed, sub_id, message}, %{sub_id: sub_id} = state) do
    send(state.consumer_pid, {:nostr_subscription, self(), {:closed, message}})
    {:stop, :normal, %{state | closed_reason: message}}
  end

  def handle_info({:nostr, :error, reason}, state) do
    send(state.consumer_pid, {:nostr_subscription, self(), {:error, reason}})
    {:stop, {:session_error, reason}, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{session_monitor_ref: ref} = state) do
    send(state.consumer_pid, {:nostr_subscription, self(), {:error, {:session_down, reason}}})
    {:stop, {:session_down, reason}, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  @spec terminate(term(), t()) :: :ok
  def terminate(_reason, %{registered?: true} = state) do
    try do
      :ok = RelaySession.unregister_subscription(state.session_pid, state.sub_id, self())
    catch
      :exit, _reason -> :ok
    end

    :ok
  end

  def terminate(_reason, _state) do
    :ok
  end

  defp register_with_session(%{registered?: true} = state) do
    {:ok, state}
  end

  defp register_with_session(state) do
    case RelaySession.register_subscription(
           state.session_pid,
           state.sub_id,
           self(),
           state.filters
         ) do
      :ok ->
        {:ok, %{state | registered?: true}}

      {:error, :not_connected} ->
        Process.send_after(self(), :register_retry, @register_retry_ms)
        {:retry, state}

      {:error, reason} ->
        send(state.consumer_pid, {:nostr_subscription, self(), {:error, reason}})
        {:error, reason, state}
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
end
