defmodule Nostr.Relay.Groups.Visibility do
  @moduledoc false

  import Ecto.Query

  alias Nostr.Event
  alias Nostr.NIP29
  alias Nostr.Relay.Repo
  alias Nostr.Relay.Store.Group
  alias Nostr.Relay.Store.GroupMember

  @spec visible?(Event.t(), [binary()], keyword()) :: boolean()
  def visible?(%Event{} = event, authenticated_pubkeys, opts)
      when is_list(authenticated_pubkeys) and is_list(opts) do
    if Keyword.get(opts, :enabled, false) do
      do_visible?(event, authenticated_pubkeys, opts)
    else
      true
    end
  end

  defp do_visible?(%Event{} = event, authenticated_pubkeys, opts) do
    case NIP29.group_id(event) do
      nil ->
        true

      group_id ->
        case Repo.get(Group, group_id) do
          nil ->
            Keyword.get(opts, :allow_unmanaged_groups, true)

          %Group{deleted: true} ->
            false

          %Group{} = group ->
            member? = Enum.any?(authenticated_pubkeys, &member?(group.group_id, &1))
            metadata? = NIP29.metadata_kind?(event.kind)

            cond do
              group.hidden and not member? -> false
              group.private and not member? and not metadata? -> false
              true -> true
            end
        end
    end
  end

  defp member?(group_id, pubkey) when is_binary(pubkey) do
    from(m in GroupMember,
      where: m.group_id == ^group_id and m.pubkey == ^pubkey and m.status == "member",
      select: m.group_id
    )
    |> Repo.exists?()
  end

  defp member?(_group_id, _pubkey), do: false
end
