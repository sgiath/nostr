defmodule Nostr.Relay.Groups.Projection do
  @moduledoc false

  import Ecto.Query

  alias Nostr.Event
  alias Nostr.NIP29
  alias Nostr.Relay.Repo
  alias Nostr.Relay.Store.Group
  alias Nostr.Relay.Store.GroupInvite
  alias Nostr.Relay.Store.GroupMember
  alias Nostr.Relay.Store.GroupRole
  alias Nostr.Tag

  @spec apply_event(Event.t(), keyword()) :: :ok | {:error, term()}
  def apply_event(%Event{} = event, opts) when is_list(opts) do
    if Keyword.get(opts, :enabled, false) do
      do_apply_event(event)
    else
      :ok
    end
  rescue
    error -> {:error, error}
  end

  defp do_apply_event(%Event{kind: kind} = event) when kind in 39_000..39_003 do
    with group_id when is_binary(group_id) <- NIP29.group_id_from_d(event),
         {:ok, group} <- ensure_group(group_id),
         :ok <- apply_metadata_snapshot(group, event) do
      :ok
    else
      _ -> :ok
    end
  end

  defp do_apply_event(%Event{kind: kind} = event) when kind in 9_000..9_022 do
    with group_id when is_binary(group_id) <- NIP29.group_id_from_h(event),
         {:ok, group} <- ensure_group(group_id) do
      apply_management_event(group, event)
    else
      _ -> :ok
    end
  end

  defp do_apply_event(%Event{} = event) do
    case NIP29.group_id_from_h(event) do
      nil ->
        :ok

      group_id ->
        case ensure_group(group_id) do
          {:ok, _group} -> :ok
          _ -> :ok
        end
    end
  end

  defp apply_management_event(%Group{} = group, %Event{kind: 9_000} = event),
    do: put_user(group, event)

  defp apply_management_event(%Group{} = group, %Event{kind: 9_001} = event),
    do: remove_user(group, event)

  defp apply_management_event(%Group{} = group, %Event{kind: 9_002} = event),
    do: edit_group_metadata(group, event)

  defp apply_management_event(%Group{} = group, %Event{kind: 9_007} = event),
    do: mark_managed(group, event)

  defp apply_management_event(%Group{} = group, %Event{kind: 9_008} = event),
    do: mark_deleted(group, event)

  defp apply_management_event(%Group{} = group, %Event{kind: 9_009} = event),
    do: create_invite(group, event)

  defp apply_management_event(%Group{} = group, %Event{kind: 9_021} = event),
    do: mark_pending(group, event)

  defp apply_management_event(%Group{} = group, %Event{kind: 9_022} = event),
    do: remove_user(group, event)

  defp apply_management_event(_group, _event), do: :ok

  defp ensure_group(group_id) do
    case Repo.get(Group, group_id) do
      %Group{} = group ->
        {:ok, group}

      nil ->
        %Group{}
        |> Group.changeset(%{group_id: group_id})
        |> Repo.insert()
    end
  end

  defp mark_managed(%Group{} = group, %Event{} = event) do
    group
    |> Group.changeset(%{
      managed: true,
      deleted: false,
      last_event_id: event.id,
      last_event_created_at: unix(event)
    })
    |> Repo.update()
    |> to_ok()
  end

  defp mark_deleted(%Group{} = group, %Event{} = event) do
    group
    |> Group.changeset(%{
      deleted: true,
      last_event_id: event.id,
      last_event_created_at: unix(event)
    })
    |> Repo.update()
    |> to_ok()
  end

  defp edit_group_metadata(%Group{} = group, %Event{tags: tags} = event) do
    attrs = %{
      name: value_for(tags, :name),
      about: value_for(tags, :about),
      picture: value_for(tags, :picture),
      private: tag_present?(tags, :private),
      restricted: tag_present?(tags, :restricted),
      hidden: tag_present?(tags, :hidden),
      closed: tag_present?(tags, :closed),
      managed: true,
      last_event_id: event.id,
      last_event_created_at: unix(event)
    }

    group
    |> Group.changeset(attrs)
    |> Repo.update()
    |> to_ok()
  end

  defp create_invite(%Group{group_id: group_id}, %Event{} = event) do
    case value_for(event.tags, :code) do
      nil ->
        :ok

      code ->
        attrs = %{
          group_id: group_id,
          code: code,
          created_by_pubkey: event.pubkey,
          create_event_id: event.id,
          created_at: unix(event)
        }

        %GroupInvite{}
        |> GroupInvite.changeset(attrs)
        |> Repo.insert(
          on_conflict: [
            set: [
              created_by_pubkey: event.pubkey,
              create_event_id: event.id,
              created_at: unix(event)
            ]
          ],
          conflict_target: [:group_id, :code]
        )
        |> to_ok()
    end
  end

  defp mark_pending(%Group{group_id: group_id}, %Event{} = event) do
    attrs = %{
      group_id: group_id,
      pubkey: event.pubkey,
      status: "pending",
      last_event_id: event.id,
      last_event_created_at: unix(event)
    }

    %GroupMember{}
    |> GroupMember.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set: [status: "pending", last_event_id: event.id, last_event_created_at: unix(event)]
      ],
      conflict_target: [:group_id, :pubkey]
    )
    |> to_ok()
  end

  defp put_user(%Group{group_id: group_id}, %Event{} = event) do
    with target when is_binary(target) <- value_for(event.tags, :p),
         :ok <- upsert_member(group_id, target, "member", event),
         :ok <- replace_roles(group_id, target, roles_for_put_user(event), event) do
      :ok
    else
      _ -> :ok
    end
  end

  defp remove_user(%Group{group_id: group_id}, %Event{} = event) do
    with target when is_binary(target) <- value_for(event.tags, :p),
         :ok <- upsert_member(group_id, target, "removed", event) do
      from(r in GroupRole, where: r.group_id == ^group_id and r.pubkey == ^target)
      |> Repo.delete_all()

      :ok
    else
      _ -> :ok
    end
  end

  defp upsert_member(group_id, pubkey, status, %Event{} = event) do
    attrs = %{
      group_id: group_id,
      pubkey: pubkey,
      status: status,
      last_event_id: event.id,
      last_event_created_at: unix(event)
    }

    %GroupMember{}
    |> GroupMember.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set: [status: status, last_event_id: event.id, last_event_created_at: unix(event)]
      ],
      conflict_target: [:group_id, :pubkey]
    )
    |> to_ok()
  end

  defp replace_roles(group_id, pubkey, roles, %Event{} = event) do
    from(r in GroupRole, where: r.group_id == ^group_id and r.pubkey == ^pubkey)
    |> Repo.delete_all()

    Enum.each(roles, fn role ->
      %GroupRole{}
      |> GroupRole.changeset(%{
        group_id: group_id,
        pubkey: pubkey,
        role: role,
        last_event_id: event.id,
        last_event_created_at: unix(event)
      })
      |> Repo.insert!()
    end)

    :ok
  end

  defp roles_for_put_user(%Event{tags: tags}) when is_list(tags) do
    tags
    |> Enum.find_value([], fn
      %Tag{type: :p, info: info} when is_list(info) -> Enum.filter(info, &is_binary/1)
      _ -> nil
    end)
  end

  defp roles_for_put_user(_event), do: []

  defp apply_metadata_snapshot(%Group{} = group, %Event{kind: 39_000, tags: tags} = event) do
    attrs = %{
      name: value_for(tags, :name),
      about: value_for(tags, :about),
      picture: value_for(tags, :picture),
      private: tag_present?(tags, :private),
      restricted: tag_present?(tags, :restricted),
      hidden: tag_present?(tags, :hidden),
      closed: tag_present?(tags, :closed),
      managed: true,
      deleted: false,
      last_event_id: event.id,
      last_event_created_at: unix(event)
    }

    group
    |> Group.changeset(attrs)
    |> Repo.update()
    |> to_ok()
  end

  defp apply_metadata_snapshot(
         %Group{group_id: group_id},
         %Event{kind: 39_001, tags: tags} = event
       ) do
    from(r in GroupRole, where: r.group_id == ^group_id)
    |> Repo.delete_all()

    tags
    |> Enum.filter(&(&1.type == :p and is_binary(&1.data)))
    |> Enum.each(fn %Tag{data: pubkey, info: roles} ->
      roles
      |> List.wrap()
      |> Enum.each(&insert_role(group_id, pubkey, &1, event))
    end)

    :ok
  end

  defp apply_metadata_snapshot(
         %Group{group_id: group_id},
         %Event{kind: 39_002, tags: tags} = event
       ) do
    from(m in GroupMember, where: m.group_id == ^group_id)
    |> Repo.delete_all()

    tags
    |> Enum.filter(&(&1.type == :p and is_binary(&1.data)))
    |> Enum.each(fn %Tag{data: pubkey} ->
      upsert_member(group_id, pubkey, "member", event)
    end)

    :ok
  end

  defp apply_metadata_snapshot(%Group{} = _group, %Event{kind: 39_003}), do: :ok
  defp apply_metadata_snapshot(_group, _event), do: :ok

  defp tag_present?(tags, type) when is_list(tags) do
    Enum.any?(tags, &(&1.type == type))
  end

  defp value_for(tags, type) when is_list(tags) do
    tags
    |> Enum.find(&(&1.type == type and is_binary(&1.data)))
    |> case do
      nil -> nil
      tag -> tag.data
    end
  end

  defp unix(%Event{created_at: %DateTime{} = created_at}), do: DateTime.to_unix(created_at)
  defp unix(_event), do: nil

  defp insert_role(group_id, pubkey, role, %Event{} = event)
       when is_binary(role) and role != "" do
    %GroupRole{}
    |> GroupRole.changeset(%{
      group_id: group_id,
      pubkey: pubkey,
      role: role,
      last_event_id: event.id,
      last_event_created_at: unix(event)
    })
    |> Repo.insert!()
  end

  defp insert_role(_group_id, _pubkey, _role, _event), do: :ok

  defp to_ok({:ok, _record}), do: :ok
  defp to_ok({:error, _} = error), do: error
end
