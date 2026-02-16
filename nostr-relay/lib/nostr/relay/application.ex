defmodule Nostr.Relay.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    server_config =
      :nostr_relay
      |> Application.get_env(:server, [])
      |> Keyword.drop([:enabled])
      |> Keyword.put_new(:plug, Nostr.Relay.Web.Router)

    children =
      [
        Nostr.Relay.Repo,
        {Phoenix.PubSub, name: Nostr.Relay.PubSub},
        {Bandit, server_config}
      ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Nostr.Relay.Supervisor)
  end
end
