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
        group_visible?(group_id, event, authenticated_pubkeys, opts)
    end
  end

  defp group_visible?(group_id, event, authenticated_pubkeys, opts) do
    case Repo.get(Group, group_id) do
      nil ->
        Keyword.get(opts, :allow_unmanaged_groups, true)

      %Group{deleted: true} ->
        false

      %Group{} = group ->
        visible_to_viewer?(group, event, authenticated_pubkeys)
    end
  end

  defp visible_to_viewer?(%Group{} = group, %Event{} = event, authenticated_pubkeys) do
    member? = Enum.any?(authenticated_pubkeys, &member?(group.group_id, &1))
    metadata? = NIP29.metadata_kind?(event.kind)

    not hidden_from_non_member?(group, member?) and
      not private_from_non_member?(group, member?, metadata?)
  end

  defp hidden_from_non_member?(%Group{hidden: true}, false), do: true
  defp hidden_from_non_member?(_group, _member?), do: false

  defp private_from_non_member?(%Group{private: true}, false, false), do: true
  defp private_from_non_member?(_group, _member?, _metadata?), do: false

  defp member?(group_id, pubkey) when is_binary(pubkey) do
    from(m in GroupMember,
      where: m.group_id == ^group_id and m.pubkey == ^pubkey and m.status == "member",
      select: m.group_id
    )
    |> Repo.exists?()
  end

  defp member?(_group_id, _pubkey), do: false
end
