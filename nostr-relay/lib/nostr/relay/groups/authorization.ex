defmodule Nostr.Relay.Groups.Authorization do
  @moduledoc false

  import Ecto.Query

  alias Nostr.Event
  alias Nostr.NIP29
  alias Nostr.Relay.Repo
  alias Nostr.Relay.Store.Group
  alias Nostr.Relay.Store.GroupInvite
  alias Nostr.Relay.Store.GroupMember
  alias Nostr.Relay.Store.GroupRole

  @spec authorize_event(Event.t(), [binary()], keyword()) :: :ok | {:error, binary()}
  def authorize_event(%Event{} = event, authenticated_pubkeys, opts)
      when is_list(authenticated_pubkeys) and is_list(opts) do
    if Keyword.get(opts, :enabled, false) do
      do_authorize_event(event, authenticated_pubkeys, opts)
    else
      :ok
    end
  end

  defp do_authorize_event(%Event{kind: kind} = event, _authenticated_pubkeys, opts)
       when kind in 39_000..39_003 do
    strict_ids? =
      opts
      |> optional_checks()
      |> Map.get(:enforce_group_id_charset, false)

    with {:ok, _group_id} <- NIP29.validate_d_tag(event, strict_group_ids: strict_ids?),
         :ok <- relay_master_event?(event, opts) do
      :ok
    else
      {:error, :missing_d_tag} -> {:error, "invalid: group metadata requires d tag"}
      {:error, :invalid_group_id} -> {:error, "invalid: group id format"}
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  defp do_authorize_event(%Event{kind: kind} = event, _authenticated_pubkeys, opts)
       when kind in 9_000..9_022 do
    strict_ids? =
      opts
      |> optional_checks()
      |> Map.get(:enforce_group_id_charset, false)

    with {:ok, group_id} <- NIP29.validate_h_tag(event, strict_group_ids: strict_ids?),
         {:ok, group} <- get_or_allow_unmanaged_group(group_id, opts),
         :ok <- maybe_enforce_closed_group_join(event, group, opts),
         :ok <- authorize_management_kind(event, group, opts) do
      :ok
    else
      {:error, :missing_h_tag} -> {:error, "invalid: group event requires h tag"}
      {:error, :invalid_group_id} -> {:error, "invalid: group id format"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
    end
  end

  defp do_authorize_event(%Event{} = event, _authenticated_pubkeys, opts) do
    case NIP29.group_id_from_h(event) do
      nil ->
        :ok

      group_id ->
        case get_or_allow_unmanaged_group(group_id, opts) do
          {:ok, group} -> authorize_group_write(event, group, opts)
          {:error, _reason} = error -> error
        end
    end
  end

  defp authorize_management_kind(%Event{kind: 9_021} = event, %Group{} = group, _opts) do
    if member?(group.group_id, event.pubkey) do
      {:error, "duplicate: already a group member"}
    else
      :ok
    end
  end

  defp authorize_management_kind(%Event{kind: 9_022} = event, %Group{} = group, _opts) do
    if member?(group.group_id, event.pubkey) do
      :ok
    else
      {:error, "restricted: cannot leave group when not a member"}
    end
  end

  defp authorize_management_kind(%Event{kind: kind} = event, %Group{} = group, opts)
       when kind in 9_000..9_020 do
    cond do
      relay_master_pubkey(opts) == event.pubkey ->
        :ok

      has_capability?(group.group_id, event.pubkey, capability_for_kind(kind), opts) ->
        :ok

      true ->
        {:error, "restricted: insufficient group role capability"}
    end
  end

  defp authorize_management_kind(_event, _group, _opts), do: :ok

  defp authorize_group_write(
         %Event{} = event,
         %Group{restricted: true, deleted: false} = group,
         _opts
       ) do
    if member?(group.group_id, event.pubkey) do
      :ok
    else
      {:error, "restricted: group write requires membership"}
    end
  end

  defp authorize_group_write(_event, %Group{deleted: true}, _opts),
    do: {:error, "restricted: group is deleted"}

  defp authorize_group_write(_event, _group, _opts), do: :ok

  defp maybe_enforce_closed_group_join(%Event{kind: 9_021} = event, %Group{} = group, opts) do
    checks = optional_checks(opts)

    if group.closed and Map.get(checks, :require_invite_for_closed_groups, false) do
      code = extract_tag_data(event, :code)

      if valid_invite?(group.group_id, code) do
        :ok
      else
        {:error, "restricted: group is closed"}
      end
    else
      :ok
    end
  end

  defp maybe_enforce_closed_group_join(_event, _group, _opts), do: :ok

  defp valid_invite?(_group_id, nil), do: false

  defp valid_invite?(group_id, code) when is_binary(code) do
    from(i in GroupInvite,
      where:
        i.group_id == ^group_id and
          i.code == ^code and
          is_nil(i.revoked_at) and
          is_nil(i.consumed_at),
      select: i.group_id
    )
    |> Repo.exists?()
  end

  defp get_or_allow_unmanaged_group(group_id, opts) do
    case Repo.get(Group, group_id) do
      %Group{} = group -> {:ok, group}
      nil -> create_or_allow_unmanaged(group_id, opts)
    end
  end

  defp create_or_allow_unmanaged(group_id, opts) do
    if Keyword.get(opts, :allow_unmanaged_groups, true) do
      {:ok, %Group{group_id: group_id, managed: false}}
    else
      {:error, "restricted: unknown group"}
    end
  end

  defp relay_master_event?(%Event{pubkey: pubkey}, opts) do
    if relay_master_pubkey(opts) == pubkey do
      :ok
    else
      {:error, "restricted: metadata events must be signed by relay pubkey"}
    end
  end

  defp relay_master_pubkey(opts) do
    relay_identity = Application.get_env(:nostr_relay, :relay_identity, [])

    Keyword.get(opts, :self_pub) || Keyword.get(relay_identity, :self_pub)
  end

  defp member?(group_id, pubkey) do
    from(m in GroupMember,
      where: m.group_id == ^group_id and m.pubkey == ^pubkey and m.status == "member",
      select: m.group_id
    )
    |> Repo.exists?()
  end

  defp has_capability?(group_id, pubkey, capability, opts) do
    roles =
      from(r in GroupRole,
        where: r.group_id == ^group_id and r.pubkey == ^pubkey,
        select: r.role
      )
      |> Repo.all()

    role_caps = Keyword.get(opts, :roles, %{})

    Enum.any?(roles, fn role ->
      capabilities_for_role(role_caps, role)
      |> Enum.member?(capability)
    end)
  end

  defp capabilities_for_role(role_caps, role) when is_map(role_caps) and is_binary(role) do
    Map.get(role_caps, role, Map.get(role_caps, safe_existing_atom(role), []))
  end

  defp capabilities_for_role(_role_caps, _role), do: []

  defp safe_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp capability_for_kind(9_000), do: :put_user
  defp capability_for_kind(9_001), do: :remove_user
  defp capability_for_kind(9_002), do: :edit_metadata
  defp capability_for_kind(9_005), do: :delete_event
  defp capability_for_kind(9_007), do: :create_group
  defp capability_for_kind(9_008), do: :delete_group
  defp capability_for_kind(9_009), do: :create_invite
  defp capability_for_kind(_kind), do: :moderate

  defp extract_tag_data(%Event{tags: tags}, type) when is_list(tags) do
    tags
    |> Enum.find(&(&1.type == type and is_binary(&1.data)))
    |> case do
      nil -> nil
      tag -> tag.data
    end
  end

  defp extract_tag_data(_event, _type), do: nil

  defp optional_checks(opts) do
    opts
    |> Keyword.get(:optional_checks, %{})
    |> Map.new()
  end
end
