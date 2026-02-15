defmodule Nostr.Relay.Pipeline.EngineTest do
  use Nostr.Relay.DataCase, async: false

  alias Nostr.Event
  alias Nostr.Message
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Engine
  alias Nostr.Relay.Pipeline.Stage
  alias Nostr.Relay.Web.ConnectionState

  describe "Engine.run/3" do
    test "returns NOTICE for invalid JSON payloads" do
      state = ConnectionState.new()

      expected =
        Message.notice("invalid message format")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } = Engine.run("{bad json", state)
    end

    test "returns NOTICE for parseable unsupported messages" do
      state = ConnectionState.new()

      payload =
        Message.notice("noop")
        |> Message.serialize()

      expected =
        Message.notice("unsupported message type")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } = Engine.run(payload, state)
    end

    test "accepts valid EVENT messages through default stages" do
      state = ConnectionState.new()
      event = valid_event()

      payload =
        event
        |> Message.create_event()
        |> Message.serialize()

      expected =
        Message.ok(event.id, true, "event accepted")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } = Engine.run(payload, state)
    end

    test "returns invalid pipeline result when a stage returns invalid output" do
      state = ConnectionState.new()

      expected =
        Message.notice("invalid pipeline result")
        |> Message.serialize()

      assert {
               :push,
               [{:text, ^expected}],
               %ConnectionState{messages: 1}
             } = Engine.run("{}", state, stages: [__MODULE__.InvalidResultStage])
    end
  end

  defmodule InvalidResultStage do
    @moduledoc false

    @behaviour Stage

    @impl Stage
    def call(%Context{} = _context, _options), do: {:ok, :not_a_context}
  end

  defp valid_event do
    valid_event([])
  end

  defp valid_event(opts) when is_list(opts) do
    created_at = Keyword.get(opts, :created_at, ~U[2024-01-01 00:00:00Z])
    kind = Keyword.get(opts, :kind, 1)

    seckey =
      Keyword.get(
        opts,
        :seckey,
        "1111111111111111111111111111111111111111111111111111111111111111"
      )

    kind
    |> Event.create(content: "relay ack", created_at: created_at)
    |> Event.sign(seckey)
  end
end
