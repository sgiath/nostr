defmodule Nostr.Relay.Pipeline.Stages.ProtocolValidatorTest do
  use Nostr.Relay.DataCase, async: false

  alias Nostr.Event
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stages.ProtocolValidator
  alias Nostr.Relay.Web.ConnectionState

  @seckey "1111111111111111111111111111111111111111111111111111111111111111"

  describe "ProtocolValidator.call/2" do
    test "returns unsupported escape error for invalid JSON escapes" do
      context = Context.new(~S(["EVENT","value\q"]), ConnectionState.new())

      assert {:error, :unsupported_json_escape, %Context{error: :unsupported_json_escape}} =
               ProtocolValidator.call(context, [])
    end

    test "returns unsupported escape error for unlisted JSON escapes" do
      context = Context.new(~S(["CLOSE","value\/"]), ConnectionState.new())

      assert {
               :error,
               :unsupported_json_escape,
               %Context{error: :unsupported_json_escape}
             } = ProtocolValidator.call(context, [])
    end

    test "returns unsupported escape error for control unicode escapes" do
      context = Context.new(~S(["CLOSE","value\u001f"]), ConnectionState.new())

      assert {
               :error,
               :unsupported_json_escape,
               %Context{error: :unsupported_json_escape}
             } = ProtocolValidator.call(context, [])
    end

    test "returns unsupported literal error for raw control characters in string" do
      raw_frame =
        IO.iodata_to_binary([
          91,
          34,
          67,
          76,
          79,
          83,
          69,
          34,
          44,
          34,
          99,
          108,
          111,
          115,
          101,
          1,
          34,
          93
        ])

      context = Context.new(raw_frame, ConnectionState.new())

      assert {:error, :unsupported_json_literals, %Context{error: :unsupported_json_literals}} =
               ProtocolValidator.call(context, [])
    end

    test "falls back to unverified event for semantic validation failures" do
      tampered_event =
        Event.create(1, created_at: ~U[2024-01-01 00:00:00Z])
        |> Event.sign(@seckey)
        |> JSON.encode!()
        |> JSON.decode!()
        |> Map.put("id", String.duplicate("0", 64))

      raw_frame = JSON.encode!(["EVENT", tampered_event])
      context = Context.new(raw_frame, ConnectionState.new())

      assert {
               :ok,
               %Context{parsed_message: {:event, parsed_event}, error: nil} = next_context
             } = ProtocolValidator.call(context, [])

      assert %Event{} = parsed_event
      assert next_context.error == nil
    end
  end
end
