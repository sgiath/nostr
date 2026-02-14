defmodule Nostr.Client do
  @moduledoc """
  Public API for relay sessions, multi-relay sessions, and subscriptions.

  One `RelaySession` is created per `{relay_url, pubkey}` key and reused.
  Use `publish/3` and `start_subscription/3` as the primary entry points.

  For multi-relay workflows, create a `Session` and use
  `publish_session/3` / `start_session_subscription/3`.

  ## Single relay quickstart

  ```elixir
  relay_url = "wss://relay.example"

  opts = [
    pubkey: MySigner.pubkey(),
    signer: MySigner
  ]

  {:ok, _session_pid} = Nostr.Client.get_or_start_session(relay_url, opts)

  event =
    1
    |> Nostr.Event.create(pubkey: MySigner.pubkey(), content: "hello")
    |> Nostr.Event.sign(MySigner.seckey())

  :ok = Nostr.Client.publish(relay_url, event, opts)

  {:ok, sub_pid} =
    Nostr.Client.start_subscription(relay_url, %Nostr.Filter{kinds: [1]}, opts)

  receive do
    {:nostr_subscription, ^sub_pid, {:event, incoming}} -> incoming
  end
  ```

  ## Multi relay quickstart

  ```elixir
  {:ok, session_pid} =
    Nostr.Client.start_session(
      pubkey: MySigner.pubkey(),
      signer: MySigner,
      relays: [
        {"wss://read-relay.example", :read},
        {"wss://rw-relay-a.example", :read_write},
        {"wss://rw-relay-b.example", :read_write}
      ]
    )

  {:ok, publish_results} = Nostr.Client.publish_session(session_pid, event)

  {:ok, session_sub_pid} =
    Nostr.Client.start_session_subscription(session_pid, [%Nostr.Filter{kinds: [1]}])

  receive do
    {:nostr_session_subscription, ^session_sub_pid, {:event, relay_url, incoming}} ->
      {relay_url, incoming.id}
  end
  ```

  ## NIP-77 negentropy quickstart

  ```elixir
  relay_url = "wss://relay.example"

  opts = [
    pubkey: MySigner.pubkey(),
    signer: MySigner
  ]

  {:ok, first_turn} =
    Nostr.Client.neg_open(
      relay_url,
      "neg-sync-1",
      %Nostr.Filter{kinds: [1]},
      initial_message,
      opts
    )

  {:ok, next_turn} = Nostr.Client.neg_msg(relay_url, "neg-sync-1", local_message, opts)
  :ok = Nostr.Client.neg_close(relay_url, "neg-sync-1", opts)
  ```
  """

  alias Nostr.Client.MultiSessionSupervisor
  alias Nostr.Client.RelayInfo
  alias Nostr.Client.RelaySession
  alias Nostr.Client.Session
  alias Nostr.Client.SessionManager
  alias Nostr.Client.SessionSubscription
  alias Nostr.Client.Subscription
  alias Nostr.Client.SubscriptionSupervisor
  alias Nostr.NIP45

  @type session_opts() :: [
          {:pubkey, binary()}
          | {:signer, module()}
          | {:notify, pid()}
          | {:transport, module()}
          | {:transport_opts, Keyword.t()}
        ]

  @type subscription_opts() :: [
          {:pubkey, binary()}
          | {:signer, module()}
          | {:notify, pid()}
          | {:transport, module()}
          | {:transport_opts, Keyword.t()}
          | {:consumer, pid()}
          | {:sub_id, binary()}
        ]

  @type relay_mode() :: :read | :read_write

  @type relay_spec() :: binary() | {binary(), relay_mode()}

  @type relay_info_opts() :: keyword()

  @type start_session_opts() :: [
          {:pubkey, binary()}
          | {:signer, module()}
          | {:notify, pid()}
          | {:transport, module()}
          | {:transport_opts, Keyword.t()}
          | {:relays, [relay_spec()]}
        ]

  @type session_subscription_opts() :: [
          {:consumer, pid()}
          | {:sub_id, binary()}
        ]

  @doc """
  Gets an existing session or starts it for the given relay URL and pubkey.

  ## Example

  ```elixir
  Nostr.Client.get_or_start_session("wss://relay.example", pubkey: pubkey, signer: signer)
  ```
  """
  @spec get_or_start_session(binary(), session_opts()) :: {:ok, pid()} | {:error, term()}
  def get_or_start_session(relay_url, opts) when is_binary(relay_url) and is_list(opts) do
    SessionManager.get_or_start_session(relay_url, opts)
  end

  @doc """
  Fetches NIP-11 relay information document for a relay URL.

  ## Example

  ```elixir
  {:ok, info} = Nostr.Client.get_relay_info("wss://relay.example")
  ```
  """
  @spec get_relay_info(binary(), relay_info_opts()) ::
          {:ok, RelayInfo.t()} | {:error, RelayInfo.reason()}
  def get_relay_info(relay_url, opts \\ []) when is_binary(relay_url) and is_list(opts) do
    RelayInfo.fetch(relay_url, opts)
  end

  @doc """
  Publishes an event through the session for relay URL + pubkey context.

  ## Example

  ```elixir
  Nostr.Client.publish("wss://relay.example", event, pubkey: pubkey, signer: signer)
  ```
  """
  @spec publish(binary(), Nostr.Event.t(), session_opts()) :: :ok | {:error, term()}
  def publish(relay_url, event, opts)
      when is_binary(relay_url) and is_struct(event, Nostr.Event) and is_list(opts) do
    with {:ok, session_pid} <- get_or_start_session(relay_url, opts) do
      RelaySession.publish(session_pid, event)
    end
  end

  @doc """
  Sends a COUNT request through the session for relay URL + pubkey context.

  ## Example

  ```elixir
  {:ok, %{count: count}} =
    Nostr.Client.count("wss://relay.example", [%Nostr.Filter{kinds: [1]}],
      pubkey: pubkey,
      signer: signer
    )
  ```
  """
  @spec count(binary(), Nostr.Filter.t() | [Nostr.Filter.t()], session_opts(), timeout()) ::
          {:ok, Nostr.Message.count_payload()} | {:error, term()}
  def count(relay_url, filters, opts, timeout \\ 5_000)
      when is_binary(relay_url) and is_list(opts) and is_integer(timeout) do
    with {:ok, session_pid} <- get_or_start_session(relay_url, opts) do
      RelaySession.count(session_pid, filters, timeout)
    end
  end

  @doc """
  Starts or replaces a NIP-77 negentropy lifecycle for `sub_id`.

  Waits for the first relay `NEG-MSG` turn.

  ## Example

  ```elixir
  {:ok, first_turn} =
    Nostr.Client.neg_open(
      "wss://relay.example",
      "neg-sync-1",
      %Nostr.Filter{kinds: [1]},
      initial_message,
      pubkey: pubkey,
      signer: signer
    )
  ```
  """
  @spec neg_open(binary(), binary(), Nostr.Filter.t(), binary(), session_opts(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def neg_open(
        relay_url,
        sub_id,
        %Nostr.Filter{} = filter,
        initial_message,
        opts,
        timeout \\ 5_000
      )
      when is_binary(relay_url) and is_binary(sub_id) and is_binary(initial_message) and
             is_list(opts) and is_integer(timeout) do
    with {:ok, session_pid} <- get_or_start_session(relay_url, opts) do
      RelaySession.neg_open(session_pid, sub_id, filter, initial_message, timeout)
    end
  end

  @doc """
  Sends the next NIP-77 negentropy message for an open lifecycle.

  Waits for relay `NEG-MSG` response.

  ## Example

  ```elixir
  {:ok, next_turn} =
    Nostr.Client.neg_msg("wss://relay.example", "neg-sync-1", local_message,
      pubkey: pubkey,
      signer: signer
    )
  ```
  """
  @spec neg_msg(binary(), binary(), binary(), session_opts(), timeout()) ::
          {:ok, binary()} | {:error, term()}
  def neg_msg(relay_url, sub_id, message, opts, timeout \\ 5_000)
      when is_binary(relay_url) and is_binary(sub_id) and is_binary(message) and is_list(opts) and
             is_integer(timeout) do
    with {:ok, session_pid} <- get_or_start_session(relay_url, opts) do
      RelaySession.neg_msg(session_pid, sub_id, message, timeout)
    end
  end

  @doc """
  Closes an open NIP-77 negentropy lifecycle.

  ## Example

  ```elixir
  :ok = Nostr.Client.neg_close("wss://relay.example", "neg-sync-1", pubkey: pubkey, signer: signer)
  ```
  """
  @spec neg_close(binary(), binary(), session_opts(), timeout()) :: :ok | {:error, term()}
  def neg_close(relay_url, sub_id, opts, timeout \\ 5_000)
      when is_binary(relay_url) and is_binary(sub_id) and is_list(opts) and is_integer(timeout) do
    with {:ok, session_pid} <- get_or_start_session(relay_url, opts) do
      RelaySession.neg_close(session_pid, sub_id, timeout)
    end
  end

  @doc """
  Starts a subscription process on top of a relay session.

  ## Example

  ```elixir
  {:ok, sub_pid} =
    Nostr.Client.start_subscription(
      "wss://relay.example",
      [%Nostr.Filter{kinds: [1]}],
      pubkey: pubkey,
      signer: signer,
      consumer: self()
    )
  ```
  """
  @spec start_subscription(binary(), Nostr.Filter.t() | [Nostr.Filter.t()], subscription_opts()) ::
          DynamicSupervisor.on_start_child()
  def start_subscription(relay_url, filters, opts)
      when is_binary(relay_url) and is_list(opts) do
    with {:ok, session_pid} <- get_or_start_session(relay_url, opts) do
      child_opts = [
        session: session_pid,
        filters: filters,
        consumer: Keyword.get(opts, :consumer, self())
      ]

      child_opts = maybe_put_sub_id(child_opts, opts)

      DynamicSupervisor.start_child(SubscriptionSupervisor, {Subscription, child_opts})
    end
  end

  @doc """
  Stops a subscription process.
  """
  @spec stop_subscription(pid(), timeout()) :: :ok
  def stop_subscription(pid, timeout \\ 5_000) when is_pid(pid) and is_integer(timeout) do
    GenServer.stop(pid, :normal, timeout)
  end

  @doc """
  Starts a logical multi-relay session process.

  ## Example

  ```elixir
  Nostr.Client.start_session(
    pubkey: pubkey,
    signer: signer,
    relays: [{"wss://relay-a.example", :read_write}, {"wss://relay-b.example", :read}]
  )
  ```
  """
  @spec start_session(start_session_opts()) :: DynamicSupervisor.on_start_child()
  def start_session(opts) when is_list(opts) do
    DynamicSupervisor.start_child(MultiSessionSupervisor, {Session, opts})
  end

  @doc """
  Stops a logical multi-relay session process.

  ## Example

  ```elixir
  :ok = Nostr.Client.stop_session(session_pid)
  ```
  """
  @spec stop_session(pid(), timeout()) :: :ok
  def stop_session(pid, timeout \\ 5_000) when is_pid(pid) and is_integer(timeout) do
    GenServer.stop(pid, :normal, timeout)
  end

  @doc """
  Adds a relay to a logical multi-relay session.

  ## Example

  ```elixir
  :ok = Nostr.Client.add_relay(session_pid, "wss://relay-new.example", :read_write)
  ```
  """
  @spec add_relay(pid(), binary(), relay_mode(), timeout()) :: :ok | {:error, term()}
  def add_relay(session_pid, relay_url, mode \\ :read_write, timeout \\ 5_000)
      when is_pid(session_pid) and is_binary(relay_url) and is_integer(timeout) do
    Session.add_relay(session_pid, relay_url, mode, timeout)
  end

  @doc """
  Removes a relay from a logical multi-relay session.

  ## Example

  ```elixir
  :ok = Nostr.Client.remove_relay(session_pid, "wss://relay-old.example")
  ```
  """
  @spec remove_relay(pid(), binary(), timeout()) :: :ok | {:error, term()}
  def remove_relay(session_pid, relay_url, timeout \\ 5_000)
      when is_pid(session_pid) and is_binary(relay_url) and is_integer(timeout) do
    Session.remove_relay(session_pid, relay_url, timeout)
  end

  @doc """
  Updates the mode of a relay in a logical multi-relay session.

  ## Example

  ```elixir
  :ok = Nostr.Client.update_relay_mode(session_pid, "wss://relay.example", :read)
  ```
  """
  @spec update_relay_mode(pid(), binary(), relay_mode(), timeout()) :: :ok | {:error, term()}
  def update_relay_mode(session_pid, relay_url, mode, timeout \\ 5_000)
      when is_pid(session_pid) and is_binary(relay_url) and is_integer(timeout) do
    Session.update_relay_mode(session_pid, relay_url, mode, timeout)
  end

  @doc """
  Lists relays currently tracked by a logical multi-relay session.

  ## Example

  ```elixir
  {:ok, relays} = Nostr.Client.list_relays(session_pid)
  ```
  """
  @spec list_relays(pid(), timeout()) :: {:ok, [Session.relay_entry()]}
  def list_relays(session_pid, timeout \\ 5_000)
      when is_pid(session_pid) and is_integer(timeout) do
    Session.list_relays(session_pid, timeout)
  end

  @doc """
  Publishes an event to all writable relays in a logical multi-relay session.

  Returns a per-relay result map.

  ## Example

  ```elixir
  {:ok, %{relay_url => result}} = Nostr.Client.publish_session(session_pid, event)
  ```
  """
  @spec publish_session(pid(), Nostr.Event.t(), timeout()) ::
          {:ok, %{binary() => :ok | {:error, term()}}} | {:error, term()}
  def publish_session(session_pid, event, timeout \\ 5_000)
      when is_pid(session_pid) and is_struct(event, Nostr.Event) and is_integer(timeout) do
    Session.publish(session_pid, event, timeout)
  end

  @doc """
  Sends a COUNT request to all readable relays in a logical multi-relay session.

  Returns a per-relay result map.

  ## Example

  ```elixir
  {:ok, %{relay_url => {:ok, %{count: count}}}} =
    Nostr.Client.count_session(session_pid, [%Nostr.Filter{kinds: [1]}])
  ```
  """
  @spec count_session(pid(), Nostr.Filter.t() | [Nostr.Filter.t()], timeout()) ::
          {:ok, %{binary() => {:ok, Nostr.Message.count_payload()} | {:error, term()}}}
          | {:error, term()}
  def count_session(session_pid, filters, timeout \\ 5_000)
      when is_pid(session_pid) and is_integer(timeout) do
    Session.count(session_pid, filters, timeout)
  end

  @doc """
  Sends a COUNT request to all readable relays and returns per-relay results
  plus NIP-45 HLL aggregation for a single filter.

  ## Example

  ```elixir
  {:ok, %{relay_results: relay_results, aggregate: aggregate}} =
    Nostr.Client.count_session_hll(session_pid, %Nostr.Filter{kinds: [7], "#e": [event_id]})
  ```
  """
  @spec count_session_hll(pid(), Nostr.Filter.t() | [Nostr.Filter.t()], timeout()) ::
          {:ok,
           %{
             relay_results: %{binary() => {:ok, Nostr.Message.count_payload()} | {:error, term()}},
             aggregate: NIP45.aggregate_result()
           }}
          | {:error, term()}
  def count_session_hll(session_pid, filters, timeout \\ 5_000)
      when is_pid(session_pid) and is_integer(timeout) do
    with {:ok, filter} <- extract_single_filter(filters),
         {:ok, relay_results} <- Session.count(session_pid, [filter], timeout),
         payloads <- collect_count_payloads(relay_results),
         {:ok, aggregate} <- NIP45.aggregate_count_payloads(filter, payloads) do
      {:ok, %{relay_results: relay_results, aggregate: aggregate}}
    end
  end

  @doc """
  Starts a logical subscription across all readable relays in a multi-relay session.

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
  @spec start_session_subscription(
          pid(),
          Nostr.Filter.t() | [Nostr.Filter.t()],
          session_subscription_opts()
        ) :: DynamicSupervisor.on_start_child()
  def start_session_subscription(session_pid, filters, opts \\ [])
      when is_pid(session_pid) and is_list(opts) do
    child_opts = [
      session: session_pid,
      filters: filters,
      consumer: Keyword.get(opts, :consumer, self())
    ]

    child_opts = maybe_put_sub_id(child_opts, opts)

    DynamicSupervisor.start_child(SubscriptionSupervisor, {SessionSubscription, child_opts})
  end

  defp maybe_put_sub_id(child_opts, opts) do
    case Keyword.fetch(opts, :sub_id) do
      {:ok, sub_id} -> Keyword.put(child_opts, :sub_id, sub_id)
      :error -> child_opts
    end
  end

  defp extract_single_filter(%Nostr.Filter{} = filter), do: {:ok, filter}

  defp extract_single_filter([%Nostr.Filter{} = filter]), do: {:ok, filter}

  defp extract_single_filter(filters) when is_list(filters) do
    if Enum.all?(filters, &match?(%Nostr.Filter{}, &1)) do
      {:error, :single_filter_required}
    else
      {:error, :invalid_filters}
    end
  end

  defp extract_single_filter(_filters), do: {:error, :invalid_filters}

  defp collect_count_payloads(relay_results) do
    relay_results
    |> Enum.reduce([], fn
      {_relay_url, {:ok, payload}}, acc -> [payload | acc]
      {_relay_url, {:error, _reason}}, acc -> acc
    end)
    |> Enum.reverse()
  end
end
