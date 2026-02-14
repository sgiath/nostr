defmodule Nostr.Client.SessionManager do
  @moduledoc """
  Singleton lookup/start manager for relay sessions.
  """

  use GenServer

  alias Nostr.Client.RelaySession
  alias Nostr.Client.SessionKey
  alias Nostr.Client.SessionSupervisor

  @type get_session_opts() :: [
          {:pubkey, binary()}
          | {:signer, module()}
          | {:notify, pid()}
          | {:transport, module()}
          | {:transport_opts, Keyword.t()}
        ]

  @doc false
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Gets an existing relay session or starts a new one.
  """
  @spec get_or_start_session(binary(), get_session_opts()) :: {:ok, pid()} | {:error, term()}
  def get_or_start_session(relay_url, opts) when is_binary(relay_url) and is_list(opts) do
    GenServer.call(__MODULE__, {:get_or_start_session, relay_url, opts})
  end

  @impl true
  @spec init(:ok) :: {:ok, %{}}
  def init(:ok) do
    {:ok, %{}}
  end

  @impl true
  @spec handle_call(
          {:get_or_start_session, binary(), get_session_opts()},
          GenServer.from(),
          map()
        ) ::
          {:reply, {:ok, pid()} | {:error, term()}, map()}
  def handle_call({:get_or_start_session, relay_url, opts}, _from, state) do
    reply =
      with {:ok, pubkey} <- fetch_pubkey(opts),
           {:ok, signer} <- fetch_signer(opts),
           {:ok, key} <- SessionKey.build(relay_url, pubkey) do
        case Registry.lookup(Nostr.Client.SessionRegistry, key) do
          [{pid, _value}] ->
            {:ok, pid}

          [] ->
            start_session(key, signer, opts)
        end
      end

    {:reply, reply, state}
  end

  defp start_session({relay_url, {:pubkey, pubkey}} = key, signer, opts) do
    name = {:via, Registry, {Nostr.Client.SessionRegistry, key}}

    child_opts =
      [
        name: name,
        relay_url: relay_url,
        pubkey: pubkey,
        signer: signer,
        session_key: key
      ] ++ passthrough_opts(opts)

    case DynamicSupervisor.start_child(SessionSupervisor, {RelaySession, child_opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp passthrough_opts(opts) do
    Keyword.take(opts, [:notify, :transport, :transport_opts])
  end

  defp fetch_pubkey(opts) do
    case Keyword.fetch(opts, :pubkey) do
      {:ok, pubkey} when is_binary(pubkey) -> {:ok, pubkey}
      {:ok, _pubkey} -> {:error, {:invalid_option, :pubkey}}
      :error -> {:error, {:missing_option, :pubkey}}
    end
  end

  defp fetch_signer(opts) do
    case Keyword.fetch(opts, :signer) do
      {:ok, signer} when is_atom(signer) -> {:ok, signer}
      {:ok, _signer} -> {:error, {:invalid_option, :signer}}
      :error -> {:error, {:missing_option, :signer}}
    end
  end
end
