defmodule Nostr.Client.Application do
  @moduledoc """
  Application supervisor for Nostr client processes.

  On boot, this starts only internal supervision infrastructure.
  Relay sessions and subscriptions are created on demand via `Nostr.Client` APIs.
  """

  use Application

  @impl true
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Nostr.Client.SessionRegistry},
      Nostr.Client.MultiSessionSupervisor,
      Nostr.Client.SessionSupervisor,
      Nostr.Client.SubscriptionSupervisor,
      Nostr.Client.SessionManager
    ]

    opts = [strategy: :one_for_one, name: Nostr.Client.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
