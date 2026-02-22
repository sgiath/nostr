defmodule Nostr.Relay.Pipeline.Stages.MessageSizeValidatorTest do
  use ExUnit.Case, async: false

  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stages.MessageSizeValidator
  alias Nostr.Relay.Web.ConnectionState

  setup do
    original_relay_info = Application.get_env(:nostr_relay, :relay_info)

    on_exit(fn ->
      Application.put_env(:nostr_relay, :relay_info, original_relay_info)
    end)

    :ok
  end

  describe "call/2" do
    test "passes when payload is within max_message_length" do
      set_max_message_length(16)
      payload = String.duplicate("a", 16)
      context = Context.new(payload, ConnectionState.new())

      assert {:ok, ^context} = MessageSizeValidator.call(context, [])
    end

    test "rejects when payload exceeds max_message_length" do
      set_max_message_length(16)
      payload = String.duplicate("a", 17)
      context = Context.new(payload, ConnectionState.new())

      assert {:error, :message_too_large, %Context{error: :message_too_large}} =
               MessageSizeValidator.call(context, [])
    end
  end

  defp set_max_message_length(max_message_length) do
    relay_info = Application.get_env(:nostr_relay, :relay_info, [])
    limitation = Keyword.get(relay_info, :limitation, %{})

    Application.put_env(
      :nostr_relay,
      :relay_info,
      Keyword.put(
        relay_info,
        :limitation,
        Map.put(limitation, :max_message_length, max_message_length)
      )
    )
  end
end
