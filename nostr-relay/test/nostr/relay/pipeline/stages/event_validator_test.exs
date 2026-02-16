defmodule Nostr.Relay.Pipeline.Stages.EventValidatorTest do
  use Nostr.Relay.DataCase, async: false

  alias Nostr.Event
  alias Nostr.Message
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stages.EventValidator
  alias Nostr.Relay.Web.ConnectionState

  describe "EventValidator.call/2" do
    test "accepts event with valid ID and signature" do
      event = valid_event()
      context = build_context({:event, event})

      assert {:ok, ^context} = EventValidator.call(context, [])
    end

    test "accepts relay-originated event with valid ID and signature" do
      event = valid_event()
      context = build_context({:event, "sub-id", event})

      assert {:ok, ^context} = EventValidator.call(context, [])
    end

    test "rejects event with tampered ID and produces OK frame" do
      event = valid_event()
      fake_id = "0000000000000000000000000000000000000000000000000000000000000000"
      tampered = %{event | id: fake_id}
      context = build_context({:event, tampered})

      assert {:error, :invalid_event_id, %Context{error: :invalid_event_id} = ctx} =
               EventValidator.call(context, [])

      assert [{:text, ok_json}] = ctx.frames
      assert ["OK", ^fake_id, false, "invalid:" <> _] = JSON.decode!(ok_json)
    end

    test "rejects event with tampered signature and produces OK frame" do
      event = valid_event()
      sig = event.sig
      last_char = String.last(sig)
      new_char = if last_char == "0", do: "1", else: "0"
      tampered_sig = String.slice(sig, 0..-2//1) <> new_char
      tampered = %{event | sig: tampered_sig}
      context = build_context({:event, tampered})

      assert {:error, :invalid_event_sig, %Context{error: :invalid_event_sig} = ctx} =
               EventValidator.call(context, [])

      assert [{:text, ok_json}] = ctx.frames

      assert ["OK", event_id, false, "invalid:" <> _] = JSON.decode!(ok_json)
      assert event_id == event.id
    end

    test "rejects event with tampered content (ID mismatch) and produces OK frame" do
      event = valid_event()
      tampered = %{event | content: "tampered content"}
      context = build_context({:event, tampered})

      assert {:error, :invalid_event_id, %Context{error: :invalid_event_id} = ctx} =
               EventValidator.call(context, [])

      assert [{:text, ok_json}] = ctx.frames
      assert ["OK", event_id, false, "invalid:" <> _] = JSON.decode!(ok_json)
      assert event_id == event.id
    end

    test "rejects event with malformed tag arrays after raw ID check" do
      raw_event = malformed_tags_event()

      wire_event = %{
        "id" => raw_event.id,
        "pubkey" => raw_event.pubkey,
        "created_at" => DateTime.to_unix(raw_event.created_at),
        "kind" => raw_event.kind,
        "tags" => raw_event.tags,
        "content" => raw_event.content,
        "sig" => raw_event.sig
      }

      parsed_event = Event.parse_unverified(wire_event)

      raw_frame = JSON.encode!(["EVENT", wire_event])

      context = build_context({:event, parsed_event}, raw_frame)

      assert {:error, :invalid_event_tags, %Context{error: :invalid_event_tags} = ctx} =
               EventValidator.call(context, [])

      assert [{:text, ok_json}] = ctx.frames

      event_id = raw_event.id
      assert ["OK", ^event_id, false, "invalid: malformed tags"] = JSON.decode!(ok_json)
    end

    test "rejects event with malformed created_at and returns created_at error" do
      event = valid_event()
      malformed = %{event | created_at: nil}
      context = build_context({:event, malformed})

      assert {:error, :invalid_event_created_at, %Context{error: :invalid_event_created_at} = ctx} =
               EventValidator.call(context, [])

      assert [{:text, ok_json}] = ctx.frames

      assert ["OK", event_id, false, "invalid: invalid created_at"] = JSON.decode!(ok_json)
      assert event_id == event.id
    end

    test "rejects event with float created_at and returns created_at error" do
      event = valid_event()
      malformed = %{event | created_at: 1.0e4}
      context = build_context({:event, malformed})

      assert {:error, :invalid_event_created_at, %Context{error: :invalid_event_created_at} = ctx} =
               EventValidator.call(context, [])

      assert [{:text, ok_json}] = ctx.frames

      assert ["OK", event_id, false, "invalid: invalid created_at"] = JSON.decode!(ok_json)
      assert event_id == event.id
    end

    test "passes through non-event messages unchanged" do
      context = build_context({:req, "sub-id", []})
      assert {:ok, ^context} = EventValidator.call(context, [])
    end

    test "passes through CLOSE messages unchanged" do
      context = build_context({:close, "sub-id"})
      assert {:ok, ^context} = EventValidator.call(context, [])
    end
  end

  describe "end-to-end pipeline rejection" do
    test "invalid signature EVENT produces OK rejection through full pipeline" do
      state = ConnectionState.new()
      event = valid_event()
      zeroed_sig = String.duplicate("0", 128)
      tampered = %{event | sig: zeroed_sig}

      payload = Message.serialize({:event, tampered})

      expected_ok =
        Message.ok(event.id, false, "invalid: event signature verification failed")
        |> Message.serialize()

      assert {:push, [{:text, ^expected_ok}], %ConnectionState{messages: 1}} =
               Nostr.Relay.Pipeline.Engine.run(payload, state)
    end

    test "invalid ID EVENT produces OK rejection through full pipeline" do
      state = ConnectionState.new()
      event = valid_event()
      fake_id = "cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe"
      tampered = %{event | id: fake_id}

      payload = Message.serialize({:event, tampered})

      expected_ok =
        Message.ok(fake_id, false, "invalid: event id does not match")
        |> Message.serialize()

      assert {:push, [{:text, ^expected_ok}], %ConnectionState{messages: 1}} =
               Nostr.Relay.Pipeline.Engine.run(payload, state)
    end

    test "invalid out-of-range created_at EVENT produces OK rejection through full pipeline" do
      state = ConnectionState.new()

      payload =
        JSON.encode!([
          "EVENT",
          %{
            "id" => "f17ba017ba0c0c16673b4bdbf63f2ca15e9f135c445d09f35f3675f7b7b5597d",
            "pubkey" => "be0e77e5ce9b00b7eb086f0e5e326900880636cf193fdb633877927f352d1f93",
            "created_at" => 9_223_372_036_854_775_807,
            "kind" => 1,
            "sig" =>
              "aa885c9e4e59e6fc3c3c4a2aaaeb1708a00d464b43777a1a9c3fc097d8398db1c5dc84b9a8564591e062d63006412611eea66db113b3289b83b4732f906df7af",
            "content" => "",
            "tags" => []
          }
        ])

      expected_ok =
        Message.ok(
          "f17ba017ba0c0c16673b4bdbf63f2ca15e9f135c445d09f35f3675f7b7b5597d",
          false,
          "invalid: invalid created_at"
        )
        |> Message.serialize()

      assert {:push, [{:text, ^expected_ok}], %ConnectionState{messages: 1}} =
               Nostr.Relay.Pipeline.Engine.run(payload, state)
    end

    test "malformed tag arrays EVENT produces OK rejection through full pipeline" do
      state = ConnectionState.new()
      event = malformed_tags_event()

      payload =
        JSON.encode!([
          "EVENT",
          %{
            "id" => event.id,
            "pubkey" => event.pubkey,
            "created_at" => DateTime.to_unix(event.created_at),
            "kind" => event.kind,
            "tags" => event.tags,
            "content" => event.content,
            "sig" => event.sig
          }
        ])

      expected_ok =
        Message.ok(event.id, false, "invalid: malformed tags")
        |> Message.serialize()

      assert {:push, [{:text, ^expected_ok}], %ConnectionState{messages: 1}} =
               Nostr.Relay.Pipeline.Engine.run(payload, state)
    end

    test "scientific notation created_at EVENT produces OK rejection through full pipeline" do
      state = ConnectionState.new()

      payload =
        JSON.encode!([
          "EVENT",
          %{
            "id" => "ba879483e2133f78fd55228455717169b61072feb7cfca2687d771dae24e0b2f",
            "pubkey" => "be0e77e5ce9b00b7eb086f0e5e326900880636cf193fdb633877927f352d1f93",
            "created_at" => 1.0e10,
            "kind" => 1,
            "sig" =>
              "e82967b0cc1ec3dd8fec43267f3b4944602f21ec1048ceb8e903a4d1aa83ed1d28aaf3a764bd29ce030d64613fd781e95ef1d0e2c9e10a943edb7b9b199fc4ee",
            "content" => "",
            "tags" => []
          }
        ])

      expected_ok =
        Message.ok(
          "ba879483e2133f78fd55228455717169b61072feb7cfca2687d771dae24e0b2f",
          false,
          "invalid: invalid created_at"
        )
        |> Message.serialize()

      assert {:push, [{:text, ^expected_ok}], %ConnectionState{messages: 1}} =
               Nostr.Relay.Pipeline.Engine.run(payload, state)
    end
  end

  defp build_context(parsed_message, raw_frame \\ ~s({"ignored":"payload"})) do
    Context.new(raw_frame, ConnectionState.new())
    |> Context.with_parsed_message(parsed_message)
  end

  defp malformed_tags_event do
    %Nostr.Event{
      kind: 1,
      created_at: ~U[2024-01-01 00:00:00Z],
      content: "event validator test",
      pubkey: nil,
      tags: [[], []],
      id: nil,
      sig: nil
    }
    |> Event.sign("1111111111111111111111111111111111111111111111111111111111111111")
  end

  defp valid_event do
    1
    |> Event.create(content: "event validator test", created_at: ~U[2024-01-01 00:00:00Z])
    |> Event.sign("1111111111111111111111111111111111111111111111111111111111111111")
  end
end
