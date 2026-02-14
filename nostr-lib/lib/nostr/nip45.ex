defmodule Nostr.NIP45 do
  @moduledoc """
  NIP-45: COUNT HyperLogLog helpers.

  Provides deterministic offset derivation, HyperLogLog register operations,
  and helper functions for aggregating COUNT payloads from multiple relays.
  """
  @moduledoc tags: [:nip45], nip: 45

  import Bitwise

  defmodule HLL do
    @moduledoc """
    HyperLogLog data structure for estimating cardinality.

    This module provides functions for creating, updating, and merging HyperLogLog
    data structures, as well as estimating the cardinality of a set of elements.
    """

    defstruct [:offset, :registers]

    @type t() :: %__MODULE__{
            offset: 8..23,
            registers: <<_::2048>>
          }
  end

  @type offset_error() :: :no_tag_filter | :multiple_tag_filters | :invalid_tag_values

  @type aggregate_result() :: %{
          fallback_sum: non_neg_integer(),
          estimate: non_neg_integer() | nil,
          hll: binary() | nil,
          used_hll_count: non_neg_integer()
        }

  @doc """
  Returns `true` when a filter can derive an HLL offset.
  """
  @spec hll_eligible?(Nostr.Filter.t() | map()) :: boolean()
  def hll_eligible?(filter), do: match?({:ok, _offset}, hll_offset(filter))

  @doc """
  Derives the deterministic NIP-45 offset for a filter.

  Currently only filters with exactly one `#<letter>` attribute are treated
  as eligible.
  """
  @spec hll_offset(Nostr.Filter.t() | map()) :: {:ok, 8..23} | {:error, offset_error()}
  def hll_offset(%Nostr.Filter{} = filter) do
    filter
    |> tag_filters_from_struct()
    |> compute_offset()
  end

  def hll_offset(filter) when is_map(filter) do
    filter
    |> tag_filters_from_map()
    |> compute_offset()
  end

  @doc """
  Creates a new empty HLL with the given offset.
  """
  @spec new(8..23) :: HLL.t()
  def new(offset) when is_integer(offset) and offset >= 8 and offset <= 23 do
    %HLL{offset: offset, registers: :binary.copy(<<0>>, 256)}
  end

  @doc """
  Creates a new empty HLL using offset derived from a filter.
  """
  @spec new_from_filter(Nostr.Filter.t() | map()) :: {:ok, HLL.t()} | {:error, offset_error()}
  def new_from_filter(filter) do
    with {:ok, offset} <- hll_offset(filter) do
      {:ok, new(offset)}
    end
  end

  @doc """
  Parses a hex-encoded HLL register payload.
  """
  @spec from_hex(binary(), 8..23) :: {:ok, HLL.t()} | {:error, :invalid_hll}
  def from_hex(hex, offset) when is_binary(hex) and is_integer(offset) do
    with true <- offset >= 8 and offset <= 23,
         {:ok, registers} <- Base.decode16(hex, case: :mixed),
         true <- byte_size(registers) == 256 do
      {:ok, %HLL{offset: offset, registers: registers}}
    else
      _error -> {:error, :invalid_hll}
    end
  end

  @doc """
  Encodes HLL registers to a hex string.
  """
  @spec to_hex(HLL.t()) :: binary()
  def to_hex(%HLL{registers: registers}) do
    Base.encode16(registers, case: :lower)
  end

  @doc """
  Merges two HLL values by taking max register values.
  """
  @spec merge(HLL.t(), HLL.t()) :: {:ok, HLL.t()} | {:error, :offset_mismatch}
  def merge(%HLL{offset: offset, registers: left}, %HLL{offset: offset, registers: right}) do
    {:ok, %HLL{offset: offset, registers: merge_registers(left, right)}}
  end

  def merge(%HLL{}, %HLL{}), do: {:error, :offset_mismatch}

  @doc """
  Adds an event pubkey into HLL registers.
  """
  @spec add_event(HLL.t(), Nostr.Event.t()) :: {:ok, HLL.t()} | {:error, :invalid_pubkey}
  def add_event(%HLL{} = hll, %Nostr.Event{pubkey: pubkey}) when is_binary(pubkey) do
    add_pubkey(hll, pubkey)
  end

  def add_event(%HLL{}, _event), do: {:error, :invalid_pubkey}

  @doc """
  Adds a hex-encoded pubkey to HLL registers.
  """
  @spec add_pubkey(HLL.t(), binary()) :: {:ok, HLL.t()} | {:error, :invalid_pubkey}
  def add_pubkey(%HLL{offset: offset, registers: registers} = hll, pubkey_hex)
      when is_binary(pubkey_hex) do
    with {:ok, pubkey} <- decode_pubkey(pubkey_hex) do
      register_index = :binary.at(pubkey, offset)
      tail = binary_part(pubkey, offset + 1, 31 - offset)
      rho = leading_zero_bits(tail) + 1

      current = :binary.at(registers, register_index)
      next = max(current, rho)

      {:ok, %{hll | registers: put_register(registers, register_index, next)}}
    end
  end

  def add_pubkey(%HLL{}, _pubkey), do: {:error, :invalid_pubkey}

  @doc """
  Returns estimated cardinality from HLL registers.
  """
  @spec estimate(HLL.t()) :: non_neg_integer()
  def estimate(%HLL{registers: registers}) do
    m = 256.0
    alpha = 0.7213 / (1.0 + 1.079 / m)

    denominator =
      registers
      |> :binary.bin_to_list()
      |> Enum.reduce(0.0, fn register, acc ->
        acc + :math.pow(2.0, -register)
      end)

    raw = alpha * m * m / denominator

    zeros =
      registers
      |> :binary.bin_to_list()
      |> Enum.count(&(&1 == 0))

    estimate =
      if raw <= 2.5 * m and zeros > 0 do
        m * :math.log(m / zeros)
      else
        raw
      end

    estimate
    |> round()
    |> max(0)
  end

  @doc """
  Aggregates COUNT payloads and merges any valid HLL values.

  Returns exact summed counts as `:fallback_sum` and approximate merged estimate
  as `:estimate` when HLL data is usable.
  """
  @spec aggregate_count_payloads(Nostr.Filter.t() | map(), [Nostr.Message.count_payload() | map()]) ::
          {:ok, aggregate_result()} | {:error, :invalid_payloads}
  def aggregate_count_payloads(filter, payloads) when is_list(payloads) do
    with {:ok, normalized} <- normalize_payloads(payloads) do
      fallback_sum = Enum.reduce(normalized, 0, fn payload, acc -> payload.count + acc end)

      case new_from_filter(filter) do
        {:ok, base_hll} ->
          {merged_hll, used_hll_count} = merge_payload_hlls(base_hll, normalized)

          result = %{
            fallback_sum: fallback_sum,
            estimate: if(used_hll_count > 0, do: estimate(merged_hll), else: nil),
            hll: if(used_hll_count > 0, do: to_hex(merged_hll), else: nil),
            used_hll_count: used_hll_count
          }

          {:ok, result}

        {:error, _offset_error} ->
          {:ok,
           %{
             fallback_sum: fallback_sum,
             estimate: nil,
             hll: nil,
             used_hll_count: 0
           }}
      end
    end
  end

  def aggregate_count_payloads(_filter, _payloads), do: {:error, :invalid_payloads}

  defp normalize_payloads(payloads) do
    payloads
    |> Enum.reduce_while({:ok, []}, fn payload, {:ok, acc} ->
      case normalize_payload(payload) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      :error -> {:error, :invalid_payloads}
    end
  end

  defp normalize_payload(%{count: count} = payload) when is_integer(count) do
    normalized = %{count: count}

    case Map.fetch(payload, :hll) do
      {:ok, hll} when is_binary(hll) -> {:ok, Map.put(normalized, :hll, hll)}
      {:ok, _hll} -> :error
      :error -> {:ok, normalized}
    end
  end

  defp normalize_payload(%{"count" => count} = payload) when is_integer(count) do
    normalized = %{count: count}

    case Map.fetch(payload, "hll") do
      {:ok, hll} when is_binary(hll) -> {:ok, Map.put(normalized, :hll, hll)}
      {:ok, _hll} -> :error
      :error -> {:ok, normalized}
    end
  end

  defp normalize_payload(_payload), do: :error

  defp merge_payload_hlls(base_hll, payloads) do
    Enum.reduce(payloads, {base_hll, 0}, fn payload, {acc_hll, used_count} ->
      case payload_hll(payload, base_hll.offset) do
        {:ok, relay_hll} ->
          {:ok, merged} = merge(acc_hll, relay_hll)
          {merged, used_count + 1}

        :skip ->
          {acc_hll, used_count}
      end
    end)
  end

  defp payload_hll(payload, offset) do
    with {:ok, hll_hex} <- Map.fetch(payload, :hll),
         {:ok, relay_hll} <- from_hex(hll_hex, offset) do
      {:ok, relay_hll}
    else
      _error -> :skip
    end
  end

  defp tag_filters_from_struct(filter) do
    top_level = [
      {"#e", Map.get(filter, :"#e")},
      {"#p", Map.get(filter, :"#p")},
      {"#a", Map.get(filter, :"#a")},
      {"#d", Map.get(filter, :"#d")}
    ]

    dynamic =
      filter
      |> Map.get(:tags)
      |> Kernel.||(%{})
      |> Enum.map(fn {key, value} -> {normalize_key(key), value} end)

    (top_level ++ dynamic)
    |> Enum.filter(&eligible_tag_filter?/1)
  end

  defp tag_filters_from_map(filter) do
    filter
    |> Enum.map(fn {key, value} -> {normalize_key(key), value} end)
    |> Enum.filter(&eligible_tag_filter?/1)
  end

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp eligible_tag_filter?({tag_key, values}) do
    valid_tag_key?(tag_key) and is_list(values) and values != []
  end

  defp valid_tag_key?("#" <> rest) when byte_size(rest) == 1, do: true
  defp valid_tag_key?(_tag_key), do: false

  defp compute_offset([]), do: {:error, :no_tag_filter}
  defp compute_offset([_one, _two | _rest]), do: {:error, :multiple_tag_filters}

  defp compute_offset([{_tag_key, [target | _rest]}]) when is_binary(target) do
    target
    |> target_hex()
    |> offset_from_target_hex()
  end

  defp compute_offset([_tag_filter]), do: {:error, :invalid_tag_values}

  defp target_hex(value) do
    if valid_32_byte_hex?(value) do
      {:ok, String.downcase(value)}
    else
      case extract_pubkey_from_address(value) do
        {:ok, pubkey} -> {:ok, String.downcase(pubkey)}
        :error -> {:ok, :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)}
      end
    end
  end

  defp extract_pubkey_from_address(value) do
    with [kind, pubkey, _identifier] <- String.split(value, ":", parts: 3),
         {_kind, ""} <- Integer.parse(kind),
         true <- valid_32_byte_hex?(pubkey) do
      {:ok, pubkey}
    else
      _error -> :error
    end
  end

  defp offset_from_target_hex({:ok, <<_prefix::binary-size(32), nibble::utf8, _rest::binary>>}) do
    case Integer.parse(<<nibble>>, 16) do
      {value, ""} -> {:ok, value + 8}
      _error -> {:error, :invalid_tag_values}
    end
  end

  defp offset_from_target_hex(_error), do: {:error, :invalid_tag_values}

  defp valid_32_byte_hex?(value) when is_binary(value) and byte_size(value) == 64 do
    case Base.decode16(value, case: :mixed) do
      {:ok, decoded} -> byte_size(decoded) == 32
      :error -> false
    end
  end

  defp valid_32_byte_hex?(_value), do: false

  defp decode_pubkey(pubkey_hex) when is_binary(pubkey_hex) and byte_size(pubkey_hex) == 64 do
    case Base.decode16(pubkey_hex, case: :mixed) do
      {:ok, pubkey} when byte_size(pubkey) == 32 -> {:ok, pubkey}
      _error -> {:error, :invalid_pubkey}
    end
  end

  defp decode_pubkey(_pubkey_hex), do: {:error, :invalid_pubkey}

  defp put_register(registers, index, value) do
    <<prefix::binary-size(index), _current::8, suffix::binary>> = registers
    <<prefix::binary, value::8, suffix::binary>>
  end

  defp merge_registers(left, right), do: merge_registers(left, right, [])

  defp merge_registers(<<>>, <<>>, acc) do
    acc
    |> Enum.reverse()
    |> :binary.list_to_bin()
  end

  defp merge_registers(<<left, left_rest::binary>>, <<right, right_rest::binary>>, acc) do
    merge_registers(left_rest, right_rest, [max(left, right) | acc])
  end

  defp leading_zero_bits(bytes), do: leading_zero_bits(bytes, 0)

  defp leading_zero_bits(<<>>, acc), do: acc

  defp leading_zero_bits(<<0, rest::binary>>, acc) do
    leading_zero_bits(rest, acc + 8)
  end

  defp leading_zero_bits(<<byte, _rest::binary>>, acc) do
    acc + leading_zero_bits_in_byte(byte)
  end

  defp leading_zero_bits_in_byte(byte), do: leading_zero_bits_in_byte(byte, 0)

  defp leading_zero_bits_in_byte(_byte, 8), do: 8

  defp leading_zero_bits_in_byte(byte, acc) do
    if (byte &&& 0x80) == 0 do
      leading_zero_bits_in_byte(byte <<< 1 &&& 0xFF, acc + 1)
    else
      acc
    end
  end
end
