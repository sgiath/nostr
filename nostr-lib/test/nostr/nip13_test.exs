defmodule Nostr.NIP13Test do
  use ExUnit.Case, async: true

  alias Nostr.NIP13
  alias Nostr.Tag
  alias Nostr.Test.Fixtures

  describe "difficulty/1" do
    test "counts leading zero bits from id" do
      assert {:ok, 0} = NIP13.difficulty("f" <> String.duplicate("0", 63))
      assert {:ok, 4} = NIP13.difficulty("0f" <> String.duplicate("0", 62))
      assert {:ok, 8} = NIP13.difficulty("00f" <> String.duplicate("0", 61))
      assert {:ok, 10} = NIP13.difficulty("002f" <> String.duplicate("0", 60))
    end

    test "returns error for invalid ids" do
      assert {:error, :invalid_event_id} = NIP13.difficulty("abc")

      assert {:error, :invalid_event_id} =
               "g"
               |> String.duplicate(64)
               |> NIP13.difficulty()

      event = Nostr.Event.create(1)
      assert {:error, :missing_event_id} = NIP13.difficulty(event)
    end
  end

  describe "nonce_commitment/1" do
    test "parses commitment from nonce tag" do
      event = %Nostr.Event{
        kind: 1,
        tags: [Tag.create(:nonce, "42", ["21"]), Tag.create(:p, Fixtures.pubkey())],
        created_at: DateTime.utc_now(),
        content: ""
      }

      assert {:ok, 21} = NIP13.nonce_commitment(event)
    end

    test "returns errors for missing or invalid commitment" do
      assert {:error, :missing_nonce_tag} = NIP13.nonce_commitment([])

      assert {:error, :missing_nonce_commitment} =
               NIP13.nonce_commitment([Tag.create(:nonce, "42")])

      assert {:error, :invalid_nonce_commitment} =
               NIP13.nonce_commitment([Tag.create(:nonce, "42", ["x"])])
    end
  end

  describe "validate_pow/3" do
    test "enforces minimum difficulty" do
      event = %Nostr.Event{
        id: "0f" <> String.duplicate("a", 62),
        kind: 1,
        tags: [Tag.create(:nonce, "1", ["8"])],
        created_at: ~U[2024-01-01 00:00:00Z],
        content: ""
      }

      assert {:error, {:insufficient_difficulty, 4, 8}} =
               NIP13.validate_pow(event, 8, require_commitment: true)
    end

    test "requires commitment when requested" do
      event = %Nostr.Event{
        id: "00f" <> String.duplicate("a", 61),
        kind: 1,
        tags: [Tag.create(:nonce, "1")],
        created_at: ~U[2024-01-01 00:00:00Z],
        content: ""
      }

      assert {:error, :missing_nonce_commitment} =
               NIP13.validate_pow(event, 8, require_commitment: true)
    end

    test "rejects commitments below required target" do
      event = %Nostr.Event{
        id: "000f" <> String.duplicate("a", 60),
        kind: 1,
        tags: [Tag.create(:nonce, "1", ["4"])],
        created_at: ~U[2024-01-01 00:00:00Z],
        content: ""
      }

      assert {:error, {:insufficient_commitment, 4, 8}} =
               NIP13.validate_pow(event, 8, require_commitment: true)
    end

    test "rejects commitments not met by actual difficulty" do
      event = %Nostr.Event{
        id: "00f" <> String.duplicate("a", 61),
        kind: 1,
        tags: [Tag.create(:nonce, "1", ["10"])],
        created_at: ~U[2024-01-01 00:00:00Z],
        content: ""
      }

      assert {:error, {:commitment_not_met, 8, 10}} =
               NIP13.validate_pow(event, 8, require_commitment: true, enforce_commitment: true)
    end

    test "accepts valid pow and commitment" do
      event = %Nostr.Event{
        id: "000f" <> String.duplicate("a", 60),
        kind: 1,
        tags: [Tag.create(:nonce, "1", ["8"])],
        created_at: ~U[2024-01-01 00:00:00Z],
        content: ""
      }

      assert :ok =
               NIP13.validate_pow(event, 8, require_commitment: true, enforce_commitment: true)
    end
  end

  describe "mine/3" do
    test "mines event and updates nonce tag" do
      event =
        Nostr.Event.create(1,
          pubkey: Fixtures.pubkey(),
          content: "mine",
          created_at: ~U[2024-01-01 00:00:00Z],
          tags: []
        )

      assert {:ok, mined} =
               NIP13.mine(event, 8,
                 update_created_at: false,
                 max_attempts: 200_000,
                 starting_nonce: 0
               )

      assert is_binary(mined.id)
      assert NIP13.meets_difficulty?(mined, 8)
      assert mined.id == Nostr.Event.compute_id(mined)
      assert {:ok, 8} = NIP13.nonce_commitment(mined)
    end

    test "returns error when attempts are exhausted" do
      event =
        Nostr.Event.create(1,
          pubkey: Fixtures.pubkey(),
          content: "mine",
          created_at: ~U[2024-01-01 00:00:00Z],
          tags: []
        )

      assert {:error, :max_attempts_exceeded} =
               NIP13.mine(event, 32,
                 update_created_at: false,
                 max_attempts: 100,
                 starting_nonce: 0
               )
    end
  end

  describe "mine_and_sign/4" do
    test "mines and signs a valid event" do
      event =
        Nostr.Event.create(1, content: "mine-and-sign", created_at: ~U[2024-01-01 00:00:00Z])

      assert {:ok, signed} =
               NIP13.mine_and_sign(event, Fixtures.seckey(), 8,
                 update_created_at: false,
                 max_attempts: 200_000,
                 starting_nonce: 0
               )

      assert Nostr.Event.Validator.valid?(signed)

      assert :ok =
               NIP13.validate_pow(signed, 8, require_commitment: true, enforce_commitment: true)
    end

    test "returns error for pubkey mismatch" do
      event =
        Nostr.Event.create(1, pubkey: Fixtures.pubkey2(), created_at: ~U[2024-01-01 00:00:00Z])

      assert {:error, :pubkey_mismatch} =
               NIP13.mine_and_sign(event, Fixtures.seckey(), 4,
                 update_created_at: false,
                 max_attempts: 100,
                 starting_nonce: 0
               )
    end
  end
end
