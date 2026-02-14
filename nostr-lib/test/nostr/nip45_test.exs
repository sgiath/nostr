defmodule Nostr.NIP45Test do
  use ExUnit.Case, async: true

  alias Nostr.NIP45
  alias Nostr.NIP45.HLL

  describe "hll_offset/1" do
    test "derives offset from pubkey hex tag" do
      filter = Nostr.Filter.parse(%{"kinds" => [3], "#p" => [String.duplicate("a", 64)]})

      assert {:ok, 18} = NIP45.hll_offset(filter)
      assert NIP45.hll_eligible?(filter)
    end

    test "derives offset from address tag pubkey part" do
      pubkey = String.duplicate("b", 64)
      filter = Nostr.Filter.parse(%{"#a" => ["30023:#{pubkey}:article-id"]})

      assert {:ok, 19} = NIP45.hll_offset(filter)
    end

    test "derives deterministic offset by hashing non-hex tag value" do
      filter = Nostr.Filter.parse(%{"#t" => ["nostr"]})

      assert {:ok, offset} = NIP45.hll_offset(filter)
      assert offset in 8..23
      assert {:ok, ^offset} = NIP45.hll_offset(filter)
    end

    test "returns error when no tag filter is present" do
      assert {:error, :no_tag_filter} = NIP45.hll_offset(%Nostr.Filter{kinds: [1]})
      refute NIP45.hll_eligible?(%Nostr.Filter{kinds: [1]})
    end

    test "returns error when multiple tag filters are present" do
      filter =
        Nostr.Filter.parse(%{
          "kinds" => [7],
          "#e" => [String.duplicate("0", 64)],
          "#p" => [String.duplicate("1", 64)]
        })

      assert {:error, :multiple_tag_filters} = NIP45.hll_offset(filter)
    end
  end

  describe "HLL helpers" do
    test "new/1, to_hex/1 and from_hex/2 roundtrip" do
      hll = NIP45.new(12)

      assert %HLL{offset: 12, registers: registers} = hll
      assert byte_size(registers) == 256

      hex = NIP45.to_hex(hll)
      assert byte_size(hex) == 512

      assert {:ok, ^hll} = NIP45.from_hex(hex, 12)
      assert {:error, :invalid_hll} = NIP45.from_hex("0011", 12)
    end

    test "merge/2 takes max value for each register" do
      left = %HLL{offset: 8, registers: register_bytes(%{5 => 3, 9 => 1})}
      right = %HLL{offset: 8, registers: register_bytes(%{5 => 2, 7 => 8})}

      assert {:ok, merged} = NIP45.merge(left, right)
      assert :binary.at(merged.registers, 5) == 3
      assert :binary.at(merged.registers, 7) == 8
      assert :binary.at(merged.registers, 9) == 1

      assert {:error, :offset_mismatch} = NIP45.merge(left, %HLL{right | offset: 9})
    end

    test "add_pubkey/2 updates target register" do
      pubkey = build_pubkey(%{8 => 3, 10 => 128})

      assert {:ok, hll} =
               8
               |> NIP45.new()
               |> NIP45.add_pubkey(pubkey)

      assert :binary.at(hll.registers, 3) == 9

      assert {:error, :invalid_pubkey} =
               8
               |> NIP45.new()
               |> NIP45.add_pubkey("invalid")
    end

    test "estimate/1 returns a positive estimate after inserts" do
      hll = NIP45.new(8)

      {:ok, hll} = NIP45.add_pubkey(hll, build_pubkey(%{8 => 1, 10 => 128}))
      {:ok, hll} = NIP45.add_pubkey(hll, build_pubkey(%{8 => 2, 9 => 64}))

      assert NIP45.estimate(hll) > 0
    end
  end

  describe "aggregate_count_payloads/2" do
    test "merges relay HLL payloads and reports estimate" do
      filter = Nostr.Filter.parse(%{"kinds" => [7], "#e" => [String.duplicate("a", 64)]})

      {:ok, base_hll} = NIP45.new_from_filter(filter)
      {:ok, hll_a} = NIP45.add_pubkey(base_hll, build_pubkey(%{18 => 4, 20 => 128}))
      {:ok, hll_b} = NIP45.add_pubkey(base_hll, build_pubkey(%{18 => 5, 19 => 64}))

      payloads = [
        %{count: 10, hll: NIP45.to_hex(hll_a)},
        %{count: 7, hll: NIP45.to_hex(hll_b)},
        %{count: 3}
      ]

      assert {:ok, result} = NIP45.aggregate_count_payloads(filter, payloads)
      assert result.fallback_sum == 20
      assert result.used_hll_count == 2
      assert is_integer(result.estimate)
      assert result.estimate > 0
      assert is_binary(result.hll)
      assert byte_size(result.hll) == 512
    end

    test "falls back to exact sum for ineligible filters" do
      filter = %Nostr.Filter{kinds: [1]}

      assert {:ok, result} =
               NIP45.aggregate_count_payloads(filter, [
                 %{count: 4, hll: String.duplicate("0", 512)}
               ])

      assert result.fallback_sum == 4
      assert result.used_hll_count == 0
      assert result.estimate == nil
      assert result.hll == nil
    end

    test "returns error for invalid payload shapes" do
      assert {:error, :invalid_payloads} =
               NIP45.aggregate_count_payloads(%Nostr.Filter{}, [%{count: "bad"}])
    end
  end

  defp register_bytes(values_by_index) do
    Enum.reduce(values_by_index, :binary.copy(<<0>>, 256), fn {index, value}, registers ->
      <<prefix::binary-size(index), _current::8, suffix::binary>> = registers
      <<prefix::binary, value::8, suffix::binary>>
    end)
  end

  defp build_pubkey(overrides) do
    overrides
    |> Enum.reduce(List.duplicate(0, 32), fn {index, value}, bytes ->
      List.replace_at(bytes, index, value)
    end)
    |> :binary.list_to_bin()
    |> Base.encode16(case: :lower)
  end
end
