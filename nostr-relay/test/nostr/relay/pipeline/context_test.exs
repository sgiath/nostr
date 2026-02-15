defmodule Nostr.Relay.Pipeline.ContextTest do
  use Nostr.Relay.DataCase, async: false

  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Web.ConnectionState

  describe "Context.new/2" do
    test "builds request context with defaults" do
      state = ConnectionState.new()

      context = Context.new(~s(["REQ", "sub"]), state)

      assert %Context{
               raw_frame: ~s(["REQ", "sub"]),
               connection_state: ^state,
               parsed_message: nil,
               frames: [],
               error: nil,
               meta: %{}
             } = context
    end
  end

  describe "Context.update helpers" do
    test "tracks mutations without mutating original value" do
      base = Context.new("payload", ConnectionState.new())

      assert %Context{
               parsed_message: {:event, :ok},
               frames: [{:text, "ok"}],
               error: :test_error,
               meta: %{path: "local"}
             } =
               base
               |> Context.with_parsed_message({:event, :ok})
               |> Context.add_frame({:text, "ok"})
               |> Context.set_error(:test_error)
               |> Context.put_meta(%{path: "local"})

      assert base.parsed_message == nil
      assert base.frames == []
      assert base.error == nil
    end
  end
end
