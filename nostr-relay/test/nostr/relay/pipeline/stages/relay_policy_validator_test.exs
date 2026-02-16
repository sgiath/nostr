defmodule Nostr.Relay.Pipeline.Stages.RelayPolicyValidatorTest do
  use ExUnit.Case, async: false

  alias Nostr.Filter
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stages.RelayPolicyValidator
  alias Nostr.Relay.Web.ConnectionState

  @full_hex String.duplicate("a", 64)

  setup do
    original = Application.get_env(:nostr_relay, :relay_info)

    on_exit(fn ->
      Application.put_env(:nostr_relay, :relay_info, original)
    end)

    :ok
  end

  describe "prefix length enforcement" do
    test "passes when min_prefix_length is 0 (disabled)" do
      set_min_prefix_length(0)

      context = build_req_context([%Filter{ids: ["ab"]}])
      assert {:ok, _context} = RelayPolicyValidator.call(context, [])
    end

    test "passes when ids and authors are nil" do
      set_min_prefix_length(8)

      context = build_req_context([%Filter{ids: nil, authors: nil}])
      assert {:ok, _context} = RelayPolicyValidator.call(context, [])
    end

    test "passes when ids contain full 64-char hex values" do
      set_min_prefix_length(8)

      context = build_req_context([%Filter{ids: [@full_hex]}])
      assert {:ok, _context} = RelayPolicyValidator.call(context, [])
    end

    test "passes when prefix meets minimum length" do
      set_min_prefix_length(8)

      context = build_req_context([%Filter{ids: ["abcdef01"]}])
      assert {:ok, _context} = RelayPolicyValidator.call(context, [])
    end

    test "rejects ids prefix shorter than minimum" do
      set_min_prefix_length(8)

      context = build_req_context([%Filter{ids: ["abc"]}])

      assert {:error, :prefix_too_short, %Context{error: :prefix_too_short}} =
               RelayPolicyValidator.call(context, [])
    end

    test "rejects authors prefix shorter than minimum" do
      set_min_prefix_length(8)

      context = build_req_context([%Filter{authors: ["ab"]}])

      assert {:error, :prefix_too_short, %Context{error: :prefix_too_short}} =
               RelayPolicyValidator.call(context, [])
    end

    test "rejects when any filter in the list has a short prefix" do
      set_min_prefix_length(8)

      filters = [
        %Filter{ids: [@full_hex]},
        %Filter{ids: ["ab"]}
      ]

      context = build_req_context(filters)

      assert {:error, :prefix_too_short, %Context{error: :prefix_too_short}} =
               RelayPolicyValidator.call(context, [])
    end

    test "applies to COUNT messages" do
      set_min_prefix_length(8)

      context = build_context({:count, "sub-1", [%Filter{ids: ["ab"]}]})

      assert {:error, :prefix_too_short, %Context{error: :prefix_too_short}} =
               RelayPolicyValidator.call(context, [])
    end

    test "passes non-REQ/COUNT messages through" do
      set_min_prefix_length(8)

      context = build_context({:close, "sub-1"})
      assert {:ok, _context} = RelayPolicyValidator.call(context, [])

      event = %Nostr.Event{kind: 1, tags: [], created_at: ~U[2024-01-01 00:00:00Z], content: ""}
      context = build_context({:event, event})
      assert {:ok, _context} = RelayPolicyValidator.call(context, [])
    end

    test "allows mix of full IDs and valid prefixes" do
      set_min_prefix_length(4)

      context = build_req_context([%Filter{ids: [@full_hex, "abcdef"]}])
      assert {:ok, _context} = RelayPolicyValidator.call(context, [])
    end
  end

  defp build_req_context(filters) do
    build_context({:req, "sub-1", filters})
  end

  defp build_context(parsed_message) do
    Context.new("{\"ignored\":\"payload\"}", ConnectionState.new())
    |> Context.with_parsed_message(parsed_message)
  end

  defp set_min_prefix_length(len) do
    info = Application.get_env(:nostr_relay, :relay_info, [])
    limits = Keyword.get(info, :limits, %{})
    new_limits = Map.put(limits, :min_prefix_length, len)
    Application.put_env(:nostr_relay, :relay_info, Keyword.put(info, :limits, new_limits))
  end
end
