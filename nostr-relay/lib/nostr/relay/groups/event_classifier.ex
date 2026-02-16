defmodule Nostr.Relay.Groups.EventClassifier do
  @moduledoc false

  alias Nostr.Event
  alias Nostr.NIP29

  @spec classification(Event.t()) ::
          :metadata | :moderation | :join_request | :leave_request | :group_scoped | :other
  def classification(%Event{kind: kind} = event) do
    cond do
      NIP29.metadata_kind?(kind) -> :metadata
      NIP29.moderation_kind?(kind) -> :moderation
      NIP29.join_request_kind?(kind) -> :join_request
      NIP29.leave_request_kind?(kind) -> :leave_request
      not is_nil(NIP29.group_id(event)) -> :group_scoped
      true -> :other
    end
  end

  @spec group_scoped?(Event.t()) :: boolean()
  def group_scoped?(%Event{} = event), do: not is_nil(NIP29.group_id(event))
end
