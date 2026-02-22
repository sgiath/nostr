defmodule Nostr.NIP13 do
  @moduledoc """
  NIP-13: Proof of Work helpers.

  Provides PoW difficulty calculation, nonce commitment parsing, validation,
  and mining helpers for Nostr events.
  """
  @moduledoc tags: [:nip13], nip: 13

  import Bitwise

  alias Nostr.Event
  alias Nostr.Tag

  @type difficulty_error() :: :missing_event_id | :invalid_event_id

  @type nonce_error() ::
          :missing_nonce_tag | :missing_nonce_commitment | :invalid_nonce_commitment

  @type pow_validation_error() ::
          difficulty_error()
          | nonce_error()
          | {:insufficient_difficulty, non_neg_integer(), non_neg_integer()}
          | {:insufficient_commitment, non_neg_integer(), non_neg_integer()}
          | {:commitment_not_met, non_neg_integer(), non_neg_integer()}

  @type mine_error() ::
          :max_attempts_exceeded
          | :invalid_created_at
          | :invalid_max_attempts
          | :invalid_commitment
          | :invalid_starting_nonce
          | :pubkey_mismatch

  @doc """
  Returns PoW difficulty as number of leading zero bits in an event id.
  """
  @spec difficulty(Event.t() | binary()) ::
          {:ok, non_neg_integer()} | {:error, difficulty_error()}
  def difficulty(%Event{id: nil}), do: {:error, :missing_event_id}
  def difficulty(%Event{id: id}) when is_binary(id), do: difficulty(id)
  def difficulty(%Event{}), do: {:error, :invalid_event_id}

  def difficulty(id) when is_binary(id) do
    with {:ok, id_bytes} <- decode_id(id) do
      {:ok, count_leading_zero_bits(id_bytes)}
    end
  end

  def difficulty(_id), do: {:error, :invalid_event_id}

  @doc """
  Returns true when an event id (or event) meets the requested PoW difficulty.
  """
  @spec meets_difficulty?(Event.t() | binary(), non_neg_integer()) :: boolean()
  def meets_difficulty?(event_or_id, required_difficulty)
      when is_integer(required_difficulty) and required_difficulty >= 0 do
    case difficulty(event_or_id) do
      {:ok, actual_difficulty} -> actual_difficulty >= required_difficulty
      {:error, _reason} -> false
    end
  end

  @doc """
  Returns the committed target difficulty from a `nonce` tag.
  """
  @spec nonce_commitment(Event.t() | [Tag.t()]) ::
          {:ok, non_neg_integer()} | {:error, nonce_error()}
  def nonce_commitment(%Event{tags: tags}) when is_list(tags), do: nonce_commitment(tags)
  def nonce_commitment(%Event{}), do: {:error, :missing_nonce_tag}

  def nonce_commitment(tags) when is_list(tags) do
    with {:ok, nonce_tag} <- nonce_tag(tags) do
      parse_commitment_from_tag(nonce_tag)
    end
  end

  def nonce_commitment(_tags), do: {:error, :missing_nonce_tag}

  @doc """
  Validates PoW and optional commitment constraints for an event.

  Options:
    - `:require_commitment` - require third nonce field (default: `false`)
    - `:enforce_commitment` - require actual difficulty >= committed target (default: `false`)
  """
  @spec validate_pow(Event.t(), non_neg_integer(), keyword()) ::
          :ok | {:error, pow_validation_error()}
  def validate_pow(%Event{} = event, min_difficulty, opts \\ [])
      when is_integer(min_difficulty) and min_difficulty >= 0 do
    require_commitment = Keyword.get(opts, :require_commitment, false)
    enforce_commitment = Keyword.get(opts, :enforce_commitment, false)

    with {:ok, actual_difficulty} <- difficulty(event),
         :ok <- validate_min_difficulty(actual_difficulty, min_difficulty),
         {:ok, commitment} <- maybe_commitment(event, require_commitment) do
      validate_commitment(actual_difficulty, commitment, min_difficulty, enforce_commitment)
    end
  end

  @doc """
  Mines an event by updating/adding its `nonce` tag until the target is met.

  Options:
    - `:max_attempts` - attempt limit (default: `1_000_000`)
    - `:starting_nonce` - nonce counter start (default: `0`)
    - `:update_created_at` - refresh timestamp on each attempt (default: `true`)
    - `:commitment` - nonce tag committed target (default: target difficulty)
  """
  @spec mine(Event.t(), non_neg_integer(), keyword()) :: {:ok, Event.t()} | {:error, mine_error()}
  def mine(%Event{} = event, target_difficulty, opts \\ [])
      when is_integer(target_difficulty) and target_difficulty >= 0 do
    with {:ok, max_attempts} <- validate_max_attempts(Keyword.get(opts, :max_attempts, 1_000_000)),
         {:ok, starting_nonce} <- validate_starting_nonce(Keyword.get(opts, :starting_nonce, 0)),
         {:ok, commitment} <-
           validate_commitment_option(Keyword.get(opts, :commitment, target_difficulty)),
         :ok <- validate_mine_created_at(event, Keyword.get(opts, :update_created_at, true)) do
      required_difficulty = max(target_difficulty, commitment)

      event
      |> mine_loop(required_difficulty, commitment, max_attempts, starting_nonce, opts)
    end
  end

  @doc """
  Mines and signs an event in one call.
  """
  @spec mine_and_sign(Event.t(), binary(), non_neg_integer(), keyword()) ::
          {:ok, Event.t()} | {:error, mine_error()}
  def mine_and_sign(%Event{} = event, seckey, target_difficulty, opts \\ [])
      when is_binary(seckey) and is_integer(target_difficulty) and target_difficulty >= 0 do
    pubkey = Nostr.Crypto.pubkey(seckey)

    with :ok <- validate_pubkey(event.pubkey, pubkey),
         {:ok, mined} <- mine(%Event{event | pubkey: pubkey}, target_difficulty, opts) do
      {:ok, Event.sign(mined, seckey)}
    end
  end

  defp validate_mine_created_at(%Event{created_at: %DateTime{}}, _update_created_at?), do: :ok
  defp validate_mine_created_at(%Event{}, true), do: :ok
  defp validate_mine_created_at(%Event{}, false), do: {:error, :invalid_created_at}

  defp validate_pubkey(nil, _pubkey), do: :ok
  defp validate_pubkey(pubkey, pubkey), do: :ok
  defp validate_pubkey(_existing, _computed), do: {:error, :pubkey_mismatch}

  defp mine_loop(event, required_difficulty, commitment, max_attempts, starting_nonce, opts)
       when is_integer(max_attempts) and max_attempts > 0 do
    update_created_at = Keyword.get(opts, :update_created_at, true)

    0..(max_attempts - 1)
    |> Enum.reduce_while({:error, :max_attempts_exceeded}, fn attempt, _acc ->
      nonce = Integer.to_string(starting_nonce + attempt)

      candidate =
        event
        |> maybe_update_created_at(update_created_at)
        |> put_nonce_tag(nonce, commitment)
        |> put_event_id()

      if meets_difficulty?(candidate, required_difficulty) do
        {:halt, {:ok, candidate}}
      else
        {:cont, {:error, :max_attempts_exceeded}}
      end
    end)
  end

  defp maybe_update_created_at(%Event{} = event, true) do
    %Event{event | created_at: DateTime.utc_now()}
  end

  defp maybe_update_created_at(%Event{} = event, false), do: event

  defp put_event_id(%Event{} = event) do
    %Event{event | id: Event.compute_id(event)}
  end

  defp put_nonce_tag(%Event{tags: tags} = event, nonce, commitment) when is_list(tags) do
    nonce_tag = Tag.create(:nonce, nonce, [Integer.to_string(commitment)])

    updated_tags =
      case Enum.find_index(tags, &nonce_tag?/1) do
        nil -> tags ++ [nonce_tag]
        index -> List.replace_at(tags, index, nonce_tag)
      end

    %Event{event | tags: updated_tags}
  end

  defp nonce_tag?(%Tag{type: :nonce}), do: true
  defp nonce_tag?(%Tag{type: "nonce"}), do: true
  defp nonce_tag?(_tag), do: false

  defp validate_min_difficulty(actual_difficulty, min_difficulty) do
    if actual_difficulty >= min_difficulty do
      :ok
    else
      {:error, {:insufficient_difficulty, actual_difficulty, min_difficulty}}
    end
  end

  defp maybe_commitment(%Event{tags: tags}, require_commitment) do
    case nonce_commitment(tags) do
      {:ok, commitment} ->
        {:ok, commitment}

      {:error, :missing_nonce_tag} when require_commitment ->
        {:error, :missing_nonce_tag}

      {:error, :missing_nonce_tag} ->
        {:ok, nil}

      {:error, :missing_nonce_commitment} when require_commitment ->
        {:error, :missing_nonce_commitment}

      {:error, :missing_nonce_commitment} ->
        {:ok, nil}

      {:error, :invalid_nonce_commitment} = error ->
        error
    end
  end

  defp validate_commitment(_actual_difficulty, nil, _min_difficulty, _enforce_commitment), do: :ok

  defp validate_commitment(actual_difficulty, commitment, min_difficulty, enforce_commitment)
       when is_integer(commitment) and commitment >= 0 do
    cond do
      commitment < min_difficulty ->
        {:error, {:insufficient_commitment, commitment, min_difficulty}}

      enforce_commitment and actual_difficulty < commitment ->
        {:error, {:commitment_not_met, actual_difficulty, commitment}}

      true ->
        :ok
    end
  end

  defp validate_max_attempts(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp validate_max_attempts(_value), do: {:error, :invalid_max_attempts}

  defp validate_starting_nonce(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp validate_starting_nonce(_value), do: {:error, :invalid_starting_nonce}

  defp validate_commitment_option(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp validate_commitment_option(_value), do: {:error, :invalid_commitment}

  defp nonce_tag(tags) when is_list(tags) do
    case Enum.find(tags, &nonce_tag?/1) do
      %Tag{} = tag -> {:ok, tag}
      _ -> {:error, :missing_nonce_tag}
    end
  end

  defp parse_commitment_from_tag(%Tag{info: [commitment | _rest]}) when is_binary(commitment) do
    parsed =
      commitment
      |> String.trim()
      |> Integer.parse()

    case parsed do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _error -> {:error, :invalid_nonce_commitment}
    end
  end

  defp parse_commitment_from_tag(%Tag{info: []}), do: {:error, :missing_nonce_commitment}
  defp parse_commitment_from_tag(%Tag{}), do: {:error, :invalid_nonce_commitment}

  defp decode_id(id) when is_binary(id) and byte_size(id) == 64 do
    case Base.decode16(id, case: :lower) do
      {:ok, bytes} when byte_size(bytes) == 32 -> {:ok, bytes}
      _error -> {:error, :invalid_event_id}
    end
  end

  defp decode_id(_id), do: {:error, :invalid_event_id}

  defp count_leading_zero_bits(bytes), do: count_leading_zero_bits(bytes, 0)

  defp count_leading_zero_bits(<<>>, acc), do: acc

  defp count_leading_zero_bits(<<0, rest::binary>>, acc) do
    count_leading_zero_bits(rest, acc + 8)
  end

  defp count_leading_zero_bits(<<byte, _rest::binary>>, acc) do
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
