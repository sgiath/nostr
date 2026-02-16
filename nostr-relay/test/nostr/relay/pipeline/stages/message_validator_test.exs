defmodule Nostr.Relay.Pipeline.Stages.MessageValidatorTest do
  use Nostr.Relay.DataCase, async: false

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stages.MessageValidator
  alias Nostr.Relay.Web.ConnectionState

  describe "MessageValidator.call/2" do
    test "accepts supported inbound message shapes" do
      assert {:ok, _context} =
               {:event, valid_event()}
               |> build_context()
               |> MessageValidator.call([])

      assert {:ok, _context} =
               {:event, "sub-id", valid_event()}
               |> build_context()
               |> MessageValidator.call([])

      assert {:ok, _context} =
               {:req, "sub-id", [%Filter{}, %Filter{}]}
               |> build_context()
               |> MessageValidator.call([])

      assert {:ok, _context} =
               {:count, "sub-id", [%Filter{}]}
               |> build_context()
               |> MessageValidator.call([])

      assert {:ok, _context} =
               {:close, "sub-id"}
               |> build_context()
               |> MessageValidator.call([])
    end

    test "rejects unsupported message forms" do
      assert {:error, :unsupported_message_type, %Context{error: :unsupported_message_type}} =
               {:notice, "noop"}
               |> build_context()
               |> MessageValidator.call([])

      assert {:error, :unsupported_message_type, %Context{error: :unsupported_message_type}} =
               {:event, %{id: "bad"}}
               |> build_context()
               |> MessageValidator.call([])

      assert {:error, :unsupported_message_type, %Context{error: :unsupported_message_type}} =
               {:req, "sub", ["bad-filter"]}
               |> build_context()
               |> MessageValidator.call([])

      assert {:error, :unsupported_message_type, %Context{error: :unsupported_message_type}} =
               {:count, "sub", %{count: 1}}
               |> build_context()
               |> MessageValidator.call([])

      assert {:error, :unsupported_message_type, %Context{error: :unsupported_message_type}} =
               {:close, :not_binary}
               |> build_context()
               |> MessageValidator.call([])
    end

    test "returns error for unsupported list cardinality and contents" do
      assert {:error, :unsupported_message_type, %Context{error: :unsupported_message_type}} =
               {:req, "sub", []}
               |> build_context()
               |> MessageValidator.call([])

      assert {:error, :unsupported_message_type, %Context{error: :unsupported_message_type}} =
               {:count, "sub", ["bad-filter", %Filter{}, :also_bad]}
               |> build_context()
               |> MessageValidator.call([])
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
