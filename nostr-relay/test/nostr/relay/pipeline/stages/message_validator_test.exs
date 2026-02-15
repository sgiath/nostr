defmodule Nostr.Relay.Pipeline.Stages.MessageValidatorTest do
  use Nostr.Relay.DataCase, async: false

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stages.MessageValidator
  alias Nostr.Relay.Web.ConnectionState

  describe "MessageValidator.call/2" do
    test "accepts supported inbound message shapes" do
      assert {:ok, _context} = MessageValidator.call(build_context({:event, valid_event()}), [])

      assert {:ok, _context} =
               MessageValidator.call(build_context({:event, "sub-id", valid_event()}), [])

      assert {:ok, _context} =
               MessageValidator.call(build_context({:req, "sub-id", [%Filter{}, %Filter{}]}), [])

      assert {:ok, _context} =
               MessageValidator.call(build_context({:count, "sub-id", [%Filter{}]}), [])

      assert {:ok, _context} = MessageValidator.call(build_context({:close, "sub-id"}), [])
    end

    test "rejects unsupported message forms" do
      assert {:error, :unsupported_message_type, %Context{error: :unsupported_message_type}} =
               MessageValidator.call(build_context({:notice, "noop"}), [])

      assert {:error, :unsupported_message_type, %Context{error: :unsupported_message_type}} =
               MessageValidator.call(build_context({:event, %{id: "bad"}}), [])

      assert {:error, :unsupported_message_type, %Context{error: :unsupported_message_type}} =
               MessageValidator.call(build_context({:req, "sub", ["bad-filter"]}), [])

      assert {:error, :unsupported_message_type, %Context{error: :unsupported_message_type}} =
               MessageValidator.call(build_context({:count, "sub", %{count: 1}}), [])

      assert {:error, :unsupported_message_type, %Context{error: :unsupported_message_type}} =
               MessageValidator.call(build_context({:close, :not_binary}), [])
    end

    test "returns error for unsupported list cardinality and contents" do
      assert {:error, :unsupported_message_type, %Context{error: :unsupported_message_type}} =
               MessageValidator.call(build_context({:req, "sub", []}), [])

      assert {:error, :unsupported_message_type, %Context{error: :unsupported_message_type}} =
               MessageValidator.call(
                 build_context({:count, "sub", ["bad-filter", %Filter{}, :also_bad]}),
                 []
               )
    end
  end

  defp build_context(parsed_message) do
    Context.new("{\"ignored\":\"payload\"}", ConnectionState.new())
    |> Context.with_parsed_message(parsed_message)
  end

  defp valid_event do
    1
    |> Event.create(content: "relay validator", created_at: ~U[2024-01-01 00:00:00Z])
    |> Event.sign("1111111111111111111111111111111111111111111111111111111111111111")
  end
end
