defmodule Nostr.Relay.Pipeline.Stages.RelayPolicyValidatorTest do
  use ExUnit.Case, async: false

  alias Nostr.Event
  alias Nostr.Filter
  alias Nostr.Relay.Pipeline.Context
  alias Nostr.Relay.Pipeline.Stages.RelayPolicyValidator
  alias Nostr.Relay.Web.ConnectionState
  alias Nostr.Tag

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

  describe "pow enforcement" do
    test "passes event when pow policy is disabled" do
      set_min_pow_difficulty(0)

      context =
        build_event_context(%Event{
          id: "f" <> String.duplicate("a", 63),
          tags: [],
          kind: 1,
          created_at: ~U[2024-01-01 00:00:00Z],
          content: ""
        })

      assert {:ok, _context} = RelayPolicyValidator.call(context, [])
    end

    test "rejects event missing nonce tag when pow is required" do
      set_min_pow_difficulty(8)

      event = %Event{
        id: "000f" <> String.duplicate("a", 60),
        tags: [],
        kind: 1,
        created_at: ~U[2024-01-01 00:00:00Z],
        content: ""
      }

      context = build_event_context(event)

      assert {:error, :pow_missing_nonce_tag, %Context{} = rejected} =
               RelayPolicyValidator.call(context, [])

      assert_ok_pow_frame(rejected, event.id, "pow: missing nonce tag")
    end

    test "rejects event missing nonce commitment when pow is required" do
      set_min_pow_difficulty(8)

      event = %Event{
        id: "000f" <> String.duplicate("a", 60),
        tags: [Tag.create(:nonce, "1")],
        kind: 1,
        created_at: ~U[2024-01-01 00:00:00Z],
        content: ""
      }

      context = build_event_context(event)

      assert {:error, :pow_missing_nonce_commitment, %Context{} = rejected} =
               RelayPolicyValidator.call(context, [])

      assert_ok_pow_frame(rejected, event.id, "pow: missing nonce commitment")
    end

    test "rejects event when committed target is below required minimum" do
      set_min_pow_difficulty(8)

      event = %Event{
        id: "000f" <> String.duplicate("a", 60),
        tags: [Tag.create(:nonce, "1", ["4"])],
        kind: 1,
        created_at: ~U[2024-01-01 00:00:00Z],
        content: ""
      }

      context = build_event_context(event)

      assert {:error, :pow_insufficient_commitment, %Context{} = rejected} =
               RelayPolicyValidator.call(context, [])

      assert_ok_pow_frame(rejected, event.id, "pow: committed target 4 is less than 8")
    end

    test "rejects event when difficulty is below required minimum" do
      set_min_pow_difficulty(8)

      event = %Event{
        id: "0f" <> String.duplicate("a", 62),
        tags: [Tag.create(:nonce, "1", ["8"])],
        kind: 1,
        created_at: ~U[2024-01-01 00:00:00Z],
        content: ""
      }

      context = build_event_context(event)

      assert {:error, :pow_insufficient_difficulty, %Context{} = rejected} =
               RelayPolicyValidator.call(context, [])

      assert_ok_pow_frame(rejected, event.id, "pow: difficulty 4 is less than 8")
    end

    test "rejects event when commitment is not met by actual difficulty" do
      set_min_pow_difficulty(8)

      event = %Event{
        id: "00f" <> String.duplicate("a", 61),
        tags: [Tag.create(:nonce, "1", ["10"])],
        kind: 1,
        created_at: ~U[2024-01-01 00:00:00Z],
        content: ""
      }

      context = build_event_context(event)

      assert {:error, :pow_commitment_not_met, %Context{} = rejected} =
               RelayPolicyValidator.call(context, [])

      assert_ok_pow_frame(
        rejected,
        event.id,
        "pow: difficulty 8 is less than committed target 10"
      )
    end

    test "accepts event when difficulty and commitment satisfy requirement" do
      set_min_pow_difficulty(8)

      event = %Event{
        id: "000f" <> String.duplicate("a", 60),
        tags: [Tag.create(:nonce, "1", ["8"])],
        kind: 1,
        created_at: ~U[2024-01-01 00:00:00Z],
        content: ""
      }

      context = build_event_context(event)

      assert {:ok, _context} = RelayPolicyValidator.call(context, [])
    end
  end

  defp build_req_context(filters) do
    build_context({:req, "sub-1", filters})
  end

  defp build_event_context(event) do
    build_context({:event, event})
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

  defp set_min_pow_difficulty(difficulty) do
    info = Application.get_env(:nostr_relay, :relay_info, [])
    limits = Keyword.get(info, :limits, %{})
    new_limits = Map.put(limits, :min_pow_difficulty, difficulty)
    Application.put_env(:nostr_relay, :relay_info, Keyword.put(info, :limits, new_limits))
  end

  defp assert_ok_pow_frame(%Context{frames: frames}, event_id, message) do
    assert [{:text, ok_json}] = frames
    assert ["OK", ^event_id, false, ^message] = JSON.decode!(ok_json)
  end
end
