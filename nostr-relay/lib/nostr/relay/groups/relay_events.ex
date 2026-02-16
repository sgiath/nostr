defmodule Nostr.Relay.Groups.RelayEvents do
  @moduledoc false

  alias Nostr.Event
  alias Nostr.Tag

  @spec relay_pubkey(keyword()) :: binary() | nil
  def relay_pubkey(opts \\ []) do
    relay_identity = Application.get_env(:nostr_relay, :relay_identity, [])
    Keyword.get(opts, :self_pub) || Keyword.get(relay_identity, :self_pub)
  end

  @spec auto_remove_user_event(binary(), binary(), binary(), keyword()) ::
          {:ok, Event.t()} | {:error, term()}
  def auto_remove_user_event(group_id, target_pubkey, reason \\ "", opts \\ [])
      when is_binary(group_id) and is_binary(target_pubkey) and is_binary(reason) and
             is_list(opts) do
    relay_identity = Application.get_env(:nostr_relay, :relay_identity, [])

    case Keyword.get(opts, :self_sec) || Keyword.get(relay_identity, :self_sec) do
      key when is_binary(key) and byte_size(key) == 64 ->
        event =
          Event.create(9_001,
            content: reason,
            tags: [Tag.create(:h, group_id), Tag.create(:p, target_pubkey)]
          )
          |> Event.sign(key)

        {:ok, event}

      _ ->
        {:error, :missing_relay_self_sec}
    end
  end
end
