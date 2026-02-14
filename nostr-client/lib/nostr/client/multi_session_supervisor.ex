defmodule Nostr.Client.MultiSessionSupervisor do
  @moduledoc """
  Dynamic supervisor for logical multi-relay session workers.
  """

  use DynamicSupervisor

  @doc false
  @spec start_link(Keyword.t()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  @spec init(:ok) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
