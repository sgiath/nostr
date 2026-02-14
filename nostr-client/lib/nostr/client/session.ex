defmodule Nostr.Client.Session do
  @moduledoc """
  Logical multi-relay session built on top of relay sessions.

  A session owns one identity (`pubkey` + signer module) and a runtime-editable
  relay set. Publishing is fanned out to writable relays. Subscriptions are
  coordinated by `Nostr.Client.SessionSubscription`.

  ## Example

  ```elixir
  {:ok, session_pid} =
    Nostr.Client.start_session(
      pubkey: pubkey,
      signer: signer,
      relays: [{"wss://relay-a.example", :read_write}, {"wss://relay-b.example", :read}]
    )

  :ok = Nostr.Client.add_relay(session_pid, "wss://relay-c.example", :read_write)
  {:ok, relay_results} = Nostr.Client.publish_session(session_pid, event)
  {:ok, relays} = Nostr.Client.list_relays(session_pid)
  ```
  """

  use GenServer

  alias Nostr.Client.RelaySession
  alias Nostr.Client.SessionKey
  alias Nostr.Client.SessionManager

  @type relay_mode() :: :read | :read_write

  @type relay_entry() :: %{
          relay_url: binary(),
          mode: relay_mode(),
          session_pid: pid()
        }

  @type option() ::
          {:pubkey, binary()}
          | {:signer, module()}
          | {:notify, pid()}
          | {:transport, module()}
          | {:transport_opts, Keyword.t()}
          | {:relays, [binary() | {binary(), relay_mode()}]}

  defstruct pubkey: nil,
            signer: nil,
            relay_notify_pid: nil,
            transport: nil,
            transport_opts: [],
            relays: %{},
            relay_monitor_refs: %{},
            subscriptions: %{},
            subscription_monitor_refs: %{},
            pending_initial_relays: []

  @type t() :: %__MODULE__{
          pubkey: binary(),
          signer: module(),
          relay_notify_pid: pid() | nil,
          transport: module() | nil,
          transport_opts: Keyword.t(),
          relays: %{binary() => map()},
          relay_monitor_refs: %{reference() => binary()},
          subscriptions: %{pid() => reference()},
          subscription_monitor_refs: %{reference() => pid()},
          pending_initial_relays: [{binary(), relay_mode()}]
        }

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
  Starts a logical multi-relay session process.

  ## Example

  ```elixir
  Nostr.Client.Session.start_link(
    pubkey: pubkey,
    signer: signer,
    relays: [{"wss://relay.example", :read_write}]
  )
  ```
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Adds a relay to the session with a mode.

  ## Example

  ```elixir
  :ok = Nostr.Client.Session.add_relay(session_pid, "wss://relay.example", :read_write)
  ```
  """
  @spec add_relay(pid(), binary(), relay_mode(), timeout()) :: :ok | {:error, term()}
  def add_relay(pid, relay_url, mode \\ :read_write, timeout \\ 5_000)
      when is_pid(pid) and is_binary(relay_url) and is_integer(timeout) do
    GenServer.call(pid, {:add_relay, relay_url, mode}, timeout)
  end

  @doc """
  Removes a relay from the session.

  ## Example

  ```elixir
  :ok = Nostr.Client.Session.remove_relay(session_pid, "wss://relay.example")
  ```
  """
  @spec remove_relay(pid(), binary(), timeout()) :: :ok | {:error, term()}
  def remove_relay(pid, relay_url, timeout \\ 5_000)
      when is_pid(pid) and is_binary(relay_url) and is_integer(timeout) do
    GenServer.call(pid, {:remove_relay, relay_url}, timeout)
  end

  @doc """
  Updates relay mode for an existing relay.

  ## Example

  ```elixir
  :ok = Nostr.Client.Session.update_relay_mode(session_pid, "wss://relay.example", :read)
  ```
  """
  @spec update_relay_mode(pid(), binary(), relay_mode(), timeout()) :: :ok | {:error, term()}
  def update_relay_mode(pid, relay_url, mode, timeout \\ 5_000)
      when is_pid(pid) and is_binary(relay_url) and is_integer(timeout) do
    GenServer.call(pid, {:update_relay_mode, relay_url, mode}, timeout)
  end

  @doc """
  Lists relays tracked by this session.

  ## Example

  ```elixir
  {:ok, relays} = Nostr.Client.Session.list_relays(session_pid)
  ```
  """
  @spec list_relays(pid(), timeout()) :: {:ok, [relay_entry()]}
  def list_relays(pid, timeout \\ 5_000) when is_pid(pid) and is_integer(timeout) do
    GenServer.call(pid, :list_relays, timeout)
  end

  @doc """
  Publishes an event to all writable relays and returns per-relay results.

  ## Example

  ```elixir
  {:ok, %{relay_url => result}} = Nostr.Client.Session.publish(session_pid, event)
  ```
  """
  @spec publish(pid(), Nostr.Event.t(), timeout()) ::
          {:ok, %{binary() => :ok | {:error, term()}}} | {:error, term()}
  def publish(pid, event, timeout \\ 5_000)
      when is_pid(pid) and is_struct(event, Nostr.Event) and is_integer(timeout) do
    GenServer.call(pid, {:publish, event, timeout}, timeout + 1_000)
  end

  @doc """
  Sends a COUNT request to all readable relays and returns per-relay results.

  ## Example

  ```elixir
  {:ok, %{relay_url => {:ok, %{count: count}}}} =
    Nostr.Client.Session.count(session_pid, [%Nostr.Filter{kinds: [1]}])
  ```
  """
  @spec count(pid(), Nostr.Filter.t() | [Nostr.Filter.t()], timeout()) ::
          {:ok, %{binary() => {:ok, Nostr.Message.count_payload()} | {:error, term()}}}
          | {:error, term()}
  def count(pid, filters, timeout \\ 5_000)
      when is_pid(pid) and is_integer(timeout) do
    GenServer.call(pid, {:count, filters, timeout}, timeout + 1_000)
  end

  @doc false
  @spec register_subscription(pid(), pid(), timeout()) ::
          {:ok, [relay_entry()]} | {:error, term()}
  def register_subscription(pid, subscriber_pid, timeout \\ 5_000)
      when is_pid(pid) and is_pid(subscriber_pid) and is_integer(timeout) do
    GenServer.call(pid, {:register_subscription, subscriber_pid}, timeout)
  end

  @doc false
  @spec unregister_subscription(pid(), pid(), timeout()) :: :ok
  def unregister_subscription(pid, subscriber_pid, timeout \\ 5_000)
      when is_pid(pid) and is_pid(subscriber_pid) and is_integer(timeout) do
    GenServer.call(pid, {:unregister_subscription, subscriber_pid}, timeout)
  end

  @impl true
  @spec init([option()]) :: {:ok, t(), {:continue, :add_initial_relays}} | {:stop, term()}
  def init(opts) do
    with {:ok, pubkey} <- fetch_pubkey(opts),
         {:ok, signer} <- fetch_signer(opts),
         {:ok, relays} <- fetch_initial_relays(opts) do
      state = %__MODULE__{
        pubkey: pubkey,
        signer: signer,
        relay_notify_pid: Keyword.get(opts, :notify),
        transport: Keyword.get(opts, :transport),
        transport_opts: Keyword.get(opts, :transport_opts, []),
        pending_initial_relays: relays
      }

      {:ok, state, {:continue, :add_initial_relays}}
    end
  end

  @impl true
  @spec handle_continue(:add_initial_relays, t()) :: {:noreply, t()}
  def handle_continue(:add_initial_relays, state) do
    next_state =
      Enum.reduce(state.pending_initial_relays, %{state | pending_initial_relays: []}, fn
        {relay_url, mode}, acc ->
          case do_add_relay(acc, relay_url, mode) do
            {:ok, updated} -> updated
            {:error, _reason, updated} -> updated
          end
      end)

    {:noreply, next_state}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), t()) :: {:reply, term(), t()}
  def handle_call({:add_relay, relay_url, mode}, _from, state) do
    with {:ok, normalized_relay_url} <- SessionKey.normalize_relay_url(relay_url),
         {:ok, relay_mode} <- validate_mode(mode),
         {:ok, next_state} <- do_add_relay(state, normalized_relay_url, relay_mode) do
      {:reply, :ok, next_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:remove_relay, relay_url}, _from, state) do
    with {:ok, normalized_relay_url} <- SessionKey.normalize_relay_url(relay_url),
         {:ok, next_state} <- do_remove_relay(state, normalized_relay_url) do
      {:reply, :ok, next_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update_relay_mode, relay_url, mode}, _from, state) do
    with {:ok, normalized_relay_url} <- SessionKey.normalize_relay_url(relay_url),
         {:ok, relay_mode} <- validate_mode(mode),
         {:ok, next_state} <- do_update_mode(state, normalized_relay_url, relay_mode) do
      {:reply, :ok, next_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_relays, _from, state) do
    entries =
      state.relays
      |> Map.values()
      |> Enum.sort_by(& &1.relay_url)
      |> Enum.map(&Map.take(&1, [:relay_url, :mode, :session_pid]))

    {:reply, {:ok, entries}, state}
  end

  def handle_call({:publish, %Nostr.Event{} = event, timeout}, _from, state) do
    writable_relays =
      state.relays
      |> Map.values()
      |> Enum.filter(&writable_mode?(&1.mode))

    if writable_relays == [] do
      {:reply, {:error, :no_writable_relays}, state}
    else
      results = publish_to_relays(writable_relays, event, timeout)
      {:reply, {:ok, results}, state}
    end
  end

  def handle_call({:count, filters, timeout}, _from, state) do
    case normalize_count_filters(filters) do
      {:ok, normalized_filters} ->
        readable_relays =
          state.relays
          |> Map.values()
          |> Enum.filter(&readable_mode?(&1.mode))

        if readable_relays == [] do
          {:reply, {:error, :no_readable_relays}, state}
        else
          results = count_relays(readable_relays, normalized_filters, timeout)
          {:reply, {:ok, results}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:register_subscription, subscriber_pid}, _from, state) do
    state = maybe_add_subscription(state, subscriber_pid)
    {:reply, {:ok, readable_relays(state)}, state}
  end

  def handle_call({:unregister_subscription, subscriber_pid}, _from, state) do
    {:reply, :ok, remove_subscription(state, subscriber_pid)}
  end

  @impl true
  @spec handle_info(term(), t()) :: {:noreply, t()}
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.fetch(state.relay_monitor_refs, ref) do
      {:ok, relay_url} ->
        next_state = remove_relay_by_url(state, relay_url, ref)

        notify_subscribers(
          next_state,
          {:nostr_session, :relay_error, relay_url, {:session_down, reason}}
        )

        notify_subscribers(next_state, {:nostr_session, :relay_removed, relay_url})
        {:noreply, next_state}

      :error ->
        case Map.fetch(state.subscription_monitor_refs, ref) do
          {:ok, subscriber_pid} -> {:noreply, remove_subscription(state, subscriber_pid, ref)}
          :error -> {:noreply, state}
        end
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp do_add_relay(state, relay_url, mode) do
    if Map.has_key?(state.relays, relay_url) do
      {:error, :relay_exists, state}
    else
      case SessionManager.get_or_start_session(relay_url, relay_session_opts(state)) do
        {:ok, session_pid} when is_pid(session_pid) ->
          monitor_ref = Process.monitor(session_pid)

          relay_entry = %{
            relay_url: relay_url,
            mode: mode,
            session_pid: session_pid,
            monitor_ref: monitor_ref
          }

          next_state = %{
            state
            | relays: Map.put(state.relays, relay_url, relay_entry),
              relay_monitor_refs: Map.put(state.relay_monitor_refs, monitor_ref, relay_url)
          }

          notify_subscribers(
            next_state,
            {:nostr_session, :relay_added, relay_url, session_pid, mode}
          )

          {:ok, next_state}

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  defp do_remove_relay(state, relay_url) do
    case Map.fetch(state.relays, relay_url) do
      :error ->
        {:error, :relay_not_found}

      {:ok, relay_entry} ->
        Process.demonitor(relay_entry.monitor_ref, [:flush])

        next_state = remove_relay_by_url(state, relay_url, relay_entry.monitor_ref)
        notify_subscribers(next_state, {:nostr_session, :relay_removed, relay_url})
        {:ok, next_state}
    end
  end

  defp do_update_mode(state, relay_url, mode) do
    case Map.fetch(state.relays, relay_url) do
      :error ->
        {:error, :relay_not_found}

      {:ok, relay_entry} ->
        next_entry = %{relay_entry | mode: mode}
        next_state = %{state | relays: Map.put(state.relays, relay_url, next_entry)}

        notify_subscribers(next_state, {
          :nostr_session,
          :relay_mode_updated,
          relay_url,
          mode,
          relay_entry.session_pid
        })

        {:ok, next_state}
    end
  end

  defp remove_relay_by_url(state, relay_url, monitor_ref) do
    %{
      state
      | relays: Map.delete(state.relays, relay_url),
        relay_monitor_refs: Map.delete(state.relay_monitor_refs, monitor_ref)
    }
  end

  defp maybe_add_subscription(state, subscriber_pid) do
    if Map.has_key?(state.subscriptions, subscriber_pid) do
      state
    else
      monitor_ref = Process.monitor(subscriber_pid)

      %{
        state
        | subscriptions: Map.put(state.subscriptions, subscriber_pid, monitor_ref),
          subscription_monitor_refs:
            Map.put(state.subscription_monitor_refs, monitor_ref, subscriber_pid)
      }
    end
  end

  defp remove_subscription(state, subscriber_pid, monitor_ref \\ nil) do
    case Map.pop(state.subscriptions, subscriber_pid) do
      {nil, _subscriptions} ->
        state

      {existing_monitor_ref, subscriptions} ->
        selected_ref = if is_reference(monitor_ref), do: monitor_ref, else: existing_monitor_ref
        Process.demonitor(selected_ref, [:flush])

        %{
          state
          | subscriptions: subscriptions,
            subscription_monitor_refs: Map.delete(state.subscription_monitor_refs, selected_ref)
        }
    end
  end

  defp readable_relays(state) do
    state.relays
    |> Map.values()
    |> Enum.filter(&readable_mode?(&1.mode))
    |> Enum.sort_by(& &1.relay_url)
    |> Enum.map(&Map.take(&1, [:relay_url, :mode, :session_pid]))
  end

  defp publish_to_relays(relays, event, timeout) do
    relays
    |> Task.async_stream(
      fn relay_entry ->
        {relay_entry.relay_url, RelaySession.publish(relay_entry.session_pid, event, timeout)}
      end,
      ordered: false,
      timeout: timeout + 100,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {relay_url, result}}, acc -> Map.put(acc, relay_url, result)
      {:exit, reason}, acc -> Map.put(acc, "task_exit", {:error, reason})
    end)
  end

  defp count_relays(relays, filters, timeout) do
    relays
    |> Task.async_stream(
      fn relay_entry ->
        {relay_entry.relay_url, RelaySession.count(relay_entry.session_pid, filters, timeout)}
      end,
      ordered: false,
      timeout: timeout + 100,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {relay_url, result}}, acc -> Map.put(acc, relay_url, result)
      {:exit, reason}, acc -> Map.put(acc, "task_exit", {:error, reason})
    end)
  end

  defp relay_session_opts(state) do
    [pubkey: state.pubkey, signer: state.signer]
    |> maybe_put(:notify, state.relay_notify_pid)
    |> maybe_put(:transport, state.transport)
    |> maybe_put(:transport_opts, state.transport_opts)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp notify_subscribers(state, message) do
    Enum.each(state.subscriptions, fn {pid, _monitor_ref} -> send(pid, message) end)
  end

  defp writable_mode?(:read_write), do: true
  defp writable_mode?(_mode), do: false

  defp readable_mode?(:read), do: true
  defp readable_mode?(:read_write), do: true
  defp readable_mode?(_mode), do: false

  defp validate_mode(:read), do: {:ok, :read}
  defp validate_mode(:read_write), do: {:ok, :read_write}
  defp validate_mode(_mode), do: {:error, :invalid_relay_mode}

  defp fetch_pubkey(opts) do
    case fetch_binary_opt(opts, :pubkey) do
      {:ok, pubkey} -> SessionKey.normalize_pubkey(pubkey)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_signer(opts) do
    case Keyword.fetch(opts, :signer) do
      {:ok, signer} when is_atom(signer) -> {:ok, signer}
      {:ok, _signer} -> {:error, {:invalid_option, :signer}}
      :error -> {:error, {:missing_option, :signer}}
    end
  end

  defp fetch_initial_relays(opts) do
    case Keyword.get(opts, :relays, []) do
      relays when is_list(relays) -> normalize_initial_relays(relays)
      _other -> {:error, {:invalid_option, :relays}}
    end
  end

  defp normalize_initial_relays(relays) do
    Enum.reduce_while(relays, {:ok, []}, fn relay_spec, {:ok, acc} ->
      with {:ok, relay_url, mode} <- normalize_relay_spec(relay_spec),
           {:ok, normalized_relay_url} <- SessionKey.normalize_relay_url(relay_url) do
        {:cont, {:ok, [{normalized_relay_url, mode} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.uniq(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_relay_spec(relay_url) when is_binary(relay_url),
    do: {:ok, relay_url, :read_write}

  defp normalize_relay_spec({relay_url, mode}) when is_binary(relay_url) do
    case validate_mode(mode) do
      {:ok, valid_mode} -> {:ok, relay_url, valid_mode}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_relay_spec(_other), do: {:error, {:invalid_option, :relays}}

  defp normalize_count_filters(%Nostr.Filter{} = filter), do: {:ok, [filter]}

  defp normalize_count_filters(filters) when is_list(filters) and filters != [] do
    if Enum.all?(filters, &match?(%Nostr.Filter{}, &1)) do
      {:ok, filters}
    else
      {:error, :invalid_filters}
    end
  end

  defp normalize_count_filters(_filters), do: {:error, :invalid_filters}

  defp fetch_binary_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:error, {:missing_option, key}}
    end
  end
end
