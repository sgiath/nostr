defmodule Nostr.Relay.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Nostr.Relay.Repo,
        relay_server_child()
      ]
      |> Enum.filter(&(&1 != nil))

    opts = [strategy: :one_for_one, name: Nostr.Relay.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @spec relay_server_child() :: Supervisor.child_spec() | nil
  defp relay_server_child do
    server_config = Application.get_env(:nostr_relay, :server, [])
    children = Keyword.get(server_config, :enabled, false)

    if children do
      {
        Bandit,
        server_config
        |> Keyword.drop([:enabled])
        |> Keyword.put_new(:plug, Nostr.Relay.Web.Router)
      }
    end
  end
end
