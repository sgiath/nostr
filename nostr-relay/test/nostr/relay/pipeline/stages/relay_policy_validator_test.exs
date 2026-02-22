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
    original_relay_policy = Application.get_env(:nostr_relay, :relay_policy)

    set_created_at_lower_limit(3_153_600_000)
    set_created_at_upper_limit(3_153_600_000)

    on_exit(fn ->
      Application.put_env(:nostr_relay, :relay_info, original)
      Application.put_env(:nostr_relay, :relay_policy, original_relay_policy)
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

  describe "subscription limit enforcement" do
    test "passes when active subscriptions are below the configured maximum" do
      set_max_subscriptions(2)

      state = ConnectionState.new() |> ConnectionState.add_subscription("sub-1", [%Filter{}])
      context = build_context({:req, "sub-2", [%Filter{}]}, state)

      assert {:ok, _context} = RelayPolicyValidator.call(context, [])
    end

    test "rejects REQ when adding a new sub_id would exceed max_subscriptions" do
      set_max_subscriptions(1)

      state = ConnectionState.new() |> ConnectionState.add_subscription("sub-1", [%Filter{}])
      context = build_context({:req, "sub-2", [%Filter{}]}, state)

      assert {:error, :too_many_subscriptions, %Context{} = rejected} =
               RelayPolicyValidator.call(context, [])

      assert [{:text, closed_json}] = rejected.frames

      assert ["CLOSED", "sub-2", "restricted: max subscriptions reached"] =
               JSON.decode!(closed_json)
    end

    test "allows replacing an existing sub_id even when at max_subscriptions" do
      set_max_subscriptions(1)

      state = ConnectionState.new() |> ConnectionState.add_subscription("sub-1", [%Filter{}])
      context = build_context({:req, "sub-1", [%Filter{}]}, state)

      assert {:ok, _context} = RelayPolicyValidator.call(context, [])
    end

    test "rejects new subscriptions when max_subscriptions is 0" do
      set_max_subscriptions(0)

      context = build_context({:req, "sub-1", [%Filter{}]})

      assert {:error, :too_many_subscriptions, %Context{} = rejected} =
               RelayPolicyValidator.call(context, [])

      assert [{:text, closed_json}] = rejected.frames

      assert ["CLOSED", "sub-1", "restricted: max subscriptions reached"] =
               JSON.decode!(closed_json)
    end
  end

  describe "subscription id length enforcement" do
    test "passes REQ/COUNT/CLOSE when sub_id is within max_subid_length" do
      set_max_subid_length(5)

      assert {:ok, _context} =
               build_context({:req, "abcde", [%Filter{}]})
               |> RelayPolicyValidator.call([])

      assert {:ok, _context} =
               build_context({:count, "abcde", [%Filter{}]})
               |> RelayPolicyValidator.call([])

      assert {:ok, _context} =
               build_context({:close, "abcde"})
               |> RelayPolicyValidator.call([])
    end

    test "rejects REQ when sub_id exceeds max_subid_length" do
      set_max_subid_length(5)

      assert {:error, :subid_too_long, %Context{error: :subid_too_long}} =
               build_context({:req, "abcdef", [%Filter{}]})
               |> RelayPolicyValidator.call([])
    end

    test "rejects COUNT when sub_id exceeds max_subid_length" do
      set_max_subid_length(5)

      assert {:error, :subid_too_long, %Context{error: :subid_too_long}} =
               build_context({:count, "abcdef", [%Filter{}]})
               |> RelayPolicyValidator.call([])
    end

    test "rejects CLOSE when sub_id exceeds max_subid_length" do
      set_max_subid_length(5)

      assert {:error, :subid_too_long, %Context{error: :subid_too_long}} =
               build_context({:close, "abcdef"})
               |> RelayPolicyValidator.call([])
    end

    test "passes when max_subid_length is 0 (disabled)" do
      set_max_subid_length(0)
      long_sub_id = String.duplicate("a", 256)

      assert {:ok, _context} =
               build_context({:req, long_sub_id, [%Filter{}]})
               |> RelayPolicyValidator.call([])

      assert {:ok, _context} =
               build_context({:count, long_sub_id, [%Filter{}]})
               |> RelayPolicyValidator.call([])

      assert {:ok, _context} =
               build_context({:close, long_sub_id})
               |> RelayPolicyValidator.call([])
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

  describe "created_at window enforcement" do
    test "rejects event older than created_at_lower_limit" do
      set_created_at_lower_limit(30)

      created_at = DateTime.add(DateTime.utc_now(), -45, :second)

      event = %Event{
        id: "f" <> String.duplicate("a", 63),
        tags: [],
        kind: 1,
        created_at: created_at,
        content: ""
      }

      context = build_event_context(event)

      assert {:error, :created_at_lower_limit_exceeded, %Context{} = rejected} =
               RelayPolicyValidator.call(context, [])

      assert [{:text, ok_json}] = rejected.frames

      assert ["OK", event_id, false, "invalid: created_at is too old"] = JSON.decode!(ok_json)
      assert event_id == event.id
    end

    test "rejects event beyond created_at_upper_limit" do
      set_created_at_upper_limit(30)

      created_at = DateTime.add(DateTime.utc_now(), 45, :second)

      event = %Event{
        id: "e" <> String.duplicate("a", 63),
        tags: [],
        kind: 1,
        created_at: created_at,
        content: ""
      }

      context = build_event_context(event)

      assert {:error, :created_at_upper_limit_exceeded, %Context{} = rejected} =
               RelayPolicyValidator.call(context, [])

      assert [{:text, ok_json}] = rejected.frames

      assert ["OK", event_id, false, "invalid: created_at is too far in the future"] =
               JSON.decode!(ok_json)

      assert event_id == event.id
    end

    test "accepts event when created_at is inside configured window" do
      set_created_at_lower_limit(30)
      set_created_at_upper_limit(30)

      event = %Event{
        id: "d" <> String.duplicate("a", 63),
        tags: [],
        kind: 1,
        created_at: DateTime.add(DateTime.utc_now(), -10, :second),
        content: ""
      }

      context = build_event_context(event)

      assert {:ok, _context} = RelayPolicyValidator.call(context, [])
    end
  end

  describe "max_event_tags enforcement" do
    test "passes when event tag count is within configured max_event_tags" do
      set_max_event_tags(2)

      event =
        %Event{
          id: "f" <> String.duplicate("a", 63),
          tags: [Tag.create(:p, "alice"), Tag.create(:e, "root")],
          kind: 1,
          created_at: ~U[2024-01-01 00:00:00Z],
          content: ""
        }

      context = build_event_context(event)

      assert {:ok, _context} = RelayPolicyValidator.call(context, [])
    end

    test "rejects when event tag count exceeds configured max_event_tags" do
      set_max_event_tags(1)

      event =
        %Event{
          id: "f" <> String.duplicate("a", 63),
          tags: [Tag.create(:p, "alice"), Tag.create(:e, "root")],
          kind: 1,
          created_at: ~U[2024-01-01 00:00:00Z],
          content: ""
        }

      context = build_event_context(event)
      event_id = event.id

      assert {:error, :too_many_event_tags, %Context{} = rejected} =
               RelayPolicyValidator.call(context, [])

      assert [{:text, ok_json}] = rejected.frames

      assert ["OK", ^event_id, false, "restricted: max event tags exceeded"] =
               JSON.decode!(ok_json)
    end
  end

  describe "max_content_length enforcement" do
    test "passes when event content length is within configured max_content_length" do
      set_max_content_length(5)

      event = %Event{
        id: "f" <> String.duplicate("a", 63),
        kind: 1,
        content: "hello",
        tags: [],
        created_at: ~U[2024-01-01 00:00:00Z]
      }

      context = build_event_context(event)

      assert {:ok, _context} = RelayPolicyValidator.call(context, [])
    end

    test "rejects when event content length exceeds configured max_content_length" do
      set_max_content_length(5)

      event = %Event{
        id: "f" <> String.duplicate("a", 63),
        kind: 1,
        content: "hello!",
        tags: [],
        created_at: ~U[2024-01-01 00:00:00Z]
      }

      context = build_event_context(event)
      event_id = event.id

      assert {:error, :content_too_long, %Context{} = rejected} =
               RelayPolicyValidator.call(context, [])

      assert [{:text, ok_json}] = rejected.frames

      assert ["OK", ^event_id, false, "restricted: max content length exceeded"] =
               JSON.decode!(ok_json)
    end
  end

  describe "max_limit clamp" do
    test "clamps REQ filter limits above configured max_limit" do
      set_default_limit(nil)
      set_max_limit(2)

      context =
        build_req_context([
          %Filter{kinds: [1], limit: 9},
          %Filter{kinds: [1], limit: 2},
          %Filter{kinds: [1], limit: 1},
          %Filter{kinds: [1], limit: nil}
        ])

      assert {:ok, %Context{parsed_message: {:req, "sub-1", filters}}} =
               RelayPolicyValidator.call(context, [])

      assert Enum.map(filters, & &1.limit) == [2, 2, 1, nil]
    end

    test "clamps COUNT filter limits above configured max_limit" do
      set_default_limit(nil)
      set_max_limit(3)

      context = build_context({:count, "sub-1", [%Filter{kinds: [1], limit: 8}]})

      assert {:ok, %Context{parsed_message: {:count, "sub-1", [%Filter{limit: 3}]}}} =
               RelayPolicyValidator.call(context, [])
    end

    test "keeps filter limits unchanged when max_limit is invalid" do
      set_default_limit(nil)
      set_max_limit(-1)

      context = build_req_context([%Filter{kinds: [1], limit: 8}])

      assert {:ok, %Context{parsed_message: {:req, "sub-1", [%Filter{limit: 8}]}}} =
               RelayPolicyValidator.call(context, [])
    end
  end

  describe "default_limit enforcement" do
    test "applies default_limit to REQ filters that omit limit" do
      set_default_limit(5)
      set_max_limit(-1)

      context =
        build_req_context([
          %Filter{kinds: [1], limit: nil},
          %Filter{kinds: [1], limit: 2}
        ])

      assert {:ok, %Context{parsed_message: {:req, "sub-1", filters}}} =
               RelayPolicyValidator.call(context, [])

      assert Enum.map(filters, & &1.limit) == [5, 2]
    end

    test "applies default_limit to COUNT filters that omit limit" do
      set_default_limit(7)
      set_max_limit(-1)

      context = build_context({:count, "sub-1", [%Filter{kinds: [1], limit: nil}]})

      assert {:ok, %Context{parsed_message: {:count, "sub-1", [%Filter{limit: 7}]}}} =
               RelayPolicyValidator.call(context, [])
    end

    test "clamps default_limit to max_limit when default_limit is higher" do
      set_default_limit(10)
      set_max_limit(3)

      context = build_req_context([%Filter{kinds: [1], limit: nil}])

      assert {:ok, %Context{parsed_message: {:req, "sub-1", [%Filter{limit: 3}]}}} =
               RelayPolicyValidator.call(context, [])
    end
  end

  defp build_req_context(filters) do
    build_context({:req, "sub-1", filters})
  end

  defp build_event_context(event) do
    build_context({:event, event})
  end

  defp build_context(parsed_message, state \\ ConnectionState.new()) do
    Context.new("{\"ignored\":\"payload\"}", state)
    |> Context.with_parsed_message(parsed_message)
  end

  defp set_min_prefix_length(len) do
    relay_policy = Application.get_env(:nostr_relay, :relay_policy, [])

    Application.put_env(
      :nostr_relay,
      :relay_policy,
      Keyword.put(relay_policy, :min_prefix_length, len)
    )
  end

  defp set_min_pow_difficulty(difficulty) do
    info = Application.get_env(:nostr_relay, :relay_info, [])
    limitation = Keyword.get(info, :limitation, %{})
    new_limitation = Map.put(limitation, :min_pow_difficulty, difficulty)
    Application.put_env(:nostr_relay, :relay_info, Keyword.put(info, :limitation, new_limitation))
  end

  defp set_created_at_lower_limit(lower_limit) do
    info = Application.get_env(:nostr_relay, :relay_info, [])
    limitation = Keyword.get(info, :limitation, %{})
    new_limitation = Map.put(limitation, :created_at_lower_limit, lower_limit)
    Application.put_env(:nostr_relay, :relay_info, Keyword.put(info, :limitation, new_limitation))
  end

  defp set_created_at_upper_limit(upper_limit) do
    info = Application.get_env(:nostr_relay, :relay_info, [])
    limitation = Keyword.get(info, :limitation, %{})
    new_limitation = Map.put(limitation, :created_at_upper_limit, upper_limit)
    Application.put_env(:nostr_relay, :relay_info, Keyword.put(info, :limitation, new_limitation))
  end

  defp set_max_limit(max_limit) do
    info = Application.get_env(:nostr_relay, :relay_info, [])
    limitation = Keyword.get(info, :limitation, %{})
    new_limitation = Map.put(limitation, :max_limit, max_limit)
    Application.put_env(:nostr_relay, :relay_info, Keyword.put(info, :limitation, new_limitation))
  end

  defp set_default_limit(default_limit) do
    info = Application.get_env(:nostr_relay, :relay_info, [])
    limitation = Keyword.get(info, :limitation, %{})
    new_limitation = Map.put(limitation, :default_limit, default_limit)
    Application.put_env(:nostr_relay, :relay_info, Keyword.put(info, :limitation, new_limitation))
  end

  defp set_max_subscriptions(max_subscriptions) do
    info = Application.get_env(:nostr_relay, :relay_info, [])
    limitation = Keyword.get(info, :limitation, %{})
    new_limitation = Map.put(limitation, :max_subscriptions, max_subscriptions)
    Application.put_env(:nostr_relay, :relay_info, Keyword.put(info, :limitation, new_limitation))
  end

  defp set_max_subid_length(max_subid_length) do
    info = Application.get_env(:nostr_relay, :relay_info, [])
    limitation = Keyword.get(info, :limitation, %{})
    new_limitation = Map.put(limitation, :max_subid_length, max_subid_length)
    Application.put_env(:nostr_relay, :relay_info, Keyword.put(info, :limitation, new_limitation))
  end

  defp set_max_event_tags(max_event_tags) do
    info = Application.get_env(:nostr_relay, :relay_info, [])
    limitation = Keyword.get(info, :limitation, %{})
    new_limitation = Map.put(limitation, :max_event_tags, max_event_tags)
    Application.put_env(:nostr_relay, :relay_info, Keyword.put(info, :limitation, new_limitation))
  end

  defp set_max_content_length(max_content_length) do
    info = Application.get_env(:nostr_relay, :relay_info, [])
    limitation = Keyword.get(info, :limitation, %{})
    new_limitation = Map.put(limitation, :max_content_length, max_content_length)
    Application.put_env(:nostr_relay, :relay_info, Keyword.put(info, :limitation, new_limitation))
  end

  defp assert_ok_pow_frame(%Context{frames: frames}, event_id, message) do
    assert [{:text, ok_json}] = frames
    assert ["OK", ^event_id, false, ^message] = JSON.decode!(ok_json)
  end
end
