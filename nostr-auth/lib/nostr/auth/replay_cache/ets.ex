defmodule Nostr.Auth.ReplayCache.ETS do
  @moduledoc """
  ETS-backed replay cache for NIP-98 event IDs.

  This cache stores event IDs with the first monotonic timestamp seen.
  Duplicate IDs are accepted within a configurable window and rejected after
  that window.

  ## Supervision

  Add this module to your supervision tree:

      {Nostr.Auth.ReplayCache.ETS, name: MyReplayCache, window_seconds: 3}

  Then wire it into auth validation:

      replay: {Nostr.Auth.ReplayCache.ETS, server: MyReplayCache}
  """

  use GenServer

  @behaviour Nostr.Auth.ReplayCache

  alias Nostr.Event

  @default_name __MODULE__
  @default_window_seconds 0

  @type state() :: %{
          table: atom() | :ets.tid(),
          window_ms: non_neg_integer()
        }

  @type check_error() :: :missing_event_id | :replayed | :invalid_window_seconds

  @doc """
  Starts the ETS replay cache process.

  ## Options

  - `:name` - process name (default: `Nostr.Auth.ReplayCache.ETS`)
  - `:table` - ETS table name atom or `:auto` for unnamed table (default: `:auto`)
  - `:window_seconds` - duplicate-acceptance window (default: `0`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Checks replay policy for an event and stores first-seen timestamp.

  `:ok` is returned for first-seen IDs and for duplicates seen within the
  configured window.

  `{:error, :replayed}` is returned for duplicates seen after the window.

  ## Options

  - `:server` - process name/pid (default: `Nostr.Auth.ReplayCache.ETS`)
  - `:window_seconds` - optional per-call window override
  """
  @impl true
  @spec check_and_store(Event.t(), keyword()) :: :ok | {:error, check_error()}
  def check_and_store(%Event{} = event, opts \\ []) do
    server = Keyword.get(opts, :server, @default_name)
    window_seconds = Keyword.get(opts, :window_seconds)

    GenServer.call(server, {:check_and_store, event.id, window_seconds})
  end

  @doc """
  Returns first-seen monotonic timestamp in milliseconds for an event ID.
  """
  @spec first_seen_at(binary(), keyword()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def first_seen_at(event_id, opts \\ []) when is_binary(event_id) do
    server = Keyword.get(opts, :server, @default_name)
    GenServer.call(server, {:first_seen_at, event_id})
  end

  @doc """
  Clears all cached entries.
  """
  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    server = Keyword.get(opts, :server, @default_name)
    GenServer.call(server, :clear)
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()} | {:stop, :invalid_window_seconds | :invalid_table}
  def init(opts) do
    window_seconds = Keyword.get(opts, :window_seconds, @default_window_seconds)

    with {:ok, window_ms} <- window_to_ms(window_seconds),
         {:ok, table} <- create_table(Keyword.get(opts, :table, :auto)) do
      {:ok, %{table: table, window_ms: window_ms}}
    else
      {:error, :invalid_window_seconds} -> {:stop, :invalid_window_seconds}
      {:error, :invalid_table} -> {:stop, :invalid_table}
    end
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) ::
          {:reply, :ok | {:error, check_error()}, state()}
          | {:reply, {:ok, non_neg_integer()} | {:error, :not_found}, state()}
  def handle_call({:check_and_store, nil, _window_seconds}, _from, state) do
    {:reply, {:error, :missing_event_id}, state}
  end

  def handle_call({:check_and_store, event_id, window_seconds}, _from, state)
      when is_binary(event_id) do
    case effective_window_ms(state.window_ms, window_seconds) do
      {:error, :invalid_window_seconds} = error ->
        {:reply, error, state}

      {:ok, window_ms} ->
        result = do_check_and_store(state.table, event_id, window_ms)
        {:reply, result, state}
    end
  end

  def handle_call({:check_and_store, _event_id, _window_seconds}, _from, state) do
    {:reply, {:error, :missing_event_id}, state}
  end

  def handle_call({:first_seen_at, event_id}, _from, state) do
    case :ets.lookup(state.table, event_id) do
      [{^event_id, first_seen_at_ms}] -> {:reply, {:ok, first_seen_at_ms}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  defp do_check_and_store(table, event_id, window_ms) do
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(table, event_id) do
      [] ->
        if :ets.insert_new(table, {event_id, now_ms}) do
          :ok
        else
          do_check_and_store(table, event_id, window_ms)
        end

      [{^event_id, first_seen_at_ms}] ->
        if now_ms - first_seen_at_ms < window_ms do
          :ok
        else
          {:error, :replayed}
        end
    end
  end

  defp effective_window_ms(default_window_ms, nil), do: {:ok, default_window_ms}

  defp effective_window_ms(_default_window_ms, window_seconds) do
    window_to_ms(window_seconds)
  end

  defp window_to_ms(window_seconds)
       when is_integer(window_seconds) and window_seconds >= 0 do
    {:ok, window_seconds * 1_000}
  end

  defp window_to_ms(_window_seconds), do: {:error, :invalid_window_seconds}

  defp create_table(:auto) do
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
    {:ok, table}
  end

  defp create_table(table) when is_atom(table) do
    :ets.new(table, [:set, :protected, :named_table, read_concurrency: true])
    {:ok, table}
  end

  defp create_table(_table), do: {:error, :invalid_table}
end
