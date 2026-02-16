defmodule Nostr.Relay.Pipeline.Stages.GroupPolicyValidator do
  @moduledoc """
  NIP-29 write-side policy gate.

  This stage validates group-scoped EVENT semantics before store insertion.
  """

  import Ecto.Query

  alias Nostr.Event
  alias Nostr.Message
  alias Nostr.NIP29
  alias Nostr.Relay.Groups
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stage
  alias Nostr.Relay.Repo
  alias Nostr.Relay.Store.Event, as: EventRecord

  @behaviour Stage

  @impl Stage
  @spec call(Context.t(), keyword()) :: {:ok, Context.t()} | {:error, atom(), Context.t()}
  def call(%Context{parsed_message: {:event, %Event{} = event}} = context, _options) do
    validate_event(event, context)
  end

  def call(%Context{parsed_message: {:event, _sub_id, %Event{} = event}} = context, _options) do
    validate_event(event, context)
  end

  def call(%Context{} = context, _options), do: {:ok, context}

  defp validate_event(%Event{} = event, %Context{connection_state: state} = context) do
    if Groups.enabled?() do
      checks =
        Groups.options()
        |> Keyword.get(:optional_checks, %{})
        |> Map.new()

      strict_ids? = Map.get(checks, :enforce_group_id_charset, false)

      with {:ok, _} <- NIP29.validate_required_group_tag(event, strict_group_ids: strict_ids?),
           :ok <- maybe_validate_previous(event, checks),
           :ok <- maybe_validate_previous_known_refs(event, checks),
           :ok <- maybe_validate_late_publication(event, checks),
           :ok <-
             Groups.authorize_write(
               event,
               MapSet.to_list(state.authenticated_pubkeys)
             ) do
        {:ok, context}
      else
        {:error, reason} when is_binary(reason) ->
          reject(context, event.id, :nip29_rejected, reason)

        {:error, :invalid_group_id} ->
          reject(context, event.id, :nip29_rejected, "invalid: group id format")

        {:error, :missing_h_tag} ->
          reject(context, event.id, :nip29_rejected, "invalid: group event requires h tag")

        {:error, :missing_d_tag} ->
          reject(context, event.id, :nip29_rejected, "invalid: group metadata requires d tag")
      end
    else
      {:ok, context}
    end
  end

  defp maybe_validate_previous(%Event{} = event, checks) do
    enforce? = Map.get(checks, :enforce_previous_refs, false)
    min_refs = Map.get(checks, :min_previous_refs, 0)
    refs = NIP29.previous_refs(event)

    cond do
      not enforce? -> :ok
      length(refs) < min_refs -> {:error, "invalid: insufficient previous references"}
      true -> :ok
    end
  end

  defp maybe_validate_late_publication(%Event{created_at: %DateTime{} = created_at}, checks) do
    if Map.get(checks, :enforce_late_publication, false) do
      max_age = Map.get(checks, :max_event_age_seconds, 86_400)
      now = DateTime.utc_now()

      if DateTime.diff(now, created_at, :second) > max_age do
        {:error, "invalid: late publication not allowed"}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp maybe_validate_late_publication(_event, _checks), do: :ok

  defp maybe_validate_previous_known_refs(%Event{} = event, checks) do
    if Map.get(checks, :enforce_previous_known_events, false) do
      refs = NIP29.previous_refs(event)

      if Enum.all?(refs, &known_previous_ref?/1) do
        :ok
      else
        {:error, "invalid: unknown previous reference"}
      end
    else
      :ok
    end
  end

  defp known_previous_ref?(ref)
       when is_binary(ref) and byte_size(ref) > 0 and byte_size(ref) <= 64 do
    from(e in EventRecord, where: like(e.event_id, ^"#{ref}%"), select: e.event_id, limit: 1)
    |> Repo.exists?()
  end

  defp known_previous_ref?(_ref), do: false

  defp reject(context, event_id, reason, message) do
    context =
      context
      |> Context.add_frame(ok_frame(event_id, false, message))
      |> Context.set_error(reason)

    {:error, reason, context}
  end

  defp ok_frame(event_id, success?, message) do
    serialized =
      event_id
      |> Message.ok(success?, message)
      |> Message.serialize()

    {:text, serialized}
  end
end
