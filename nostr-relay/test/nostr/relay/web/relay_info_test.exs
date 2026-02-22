defmodule Nostr.Relay.Web.RelayInfoTest do
  use ExUnit.Case, async: false

  alias Nostr.Relay.Web.RelayInfo

  setup do
    original_info = Application.get_env(:nostr_relay, :relay_info)
    original_identity = Application.get_env(:nostr_relay, :relay_identity)
    original_auth = Application.get_env(:nostr_relay, :auth)
    original_nip29 = Application.get_env(:nostr_relay, :nip29)

    on_exit(fn ->
      Application.put_env(:nostr_relay, :relay_info, original_info)
      Application.put_env(:nostr_relay, :relay_identity, original_identity)
      Application.put_env(:nostr_relay, :auth, original_auth)
      Application.put_env(:nostr_relay, :nip29, original_nip29)
    end)

    :ok
  end

  test "does not advertise NIP-29 when disabled" do
    Application.put_env(:nostr_relay, :relay_info, supported_nips: [1, 11, 42])
    Application.put_env(:nostr_relay, :nip29, enabled: false)

    metadata = RelayInfo.metadata()
    refute 29 in metadata["supported_nips"]
    assert 13 in metadata["supported_nips"]
    assert 70 in metadata["supported_nips"]
  end

  test "advertises NIP-29 when enabled" do
    Application.put_env(:nostr_relay, :relay_info, supported_nips: [1, 11, 42])
    Application.put_env(:nostr_relay, :nip29, enabled: true)

    metadata = RelayInfo.metadata()
    assert 29 in metadata["supported_nips"]
    assert 13 in metadata["supported_nips"]
    assert 70 in metadata["supported_nips"]
  end

  test "always advertises NIP-13 and NIP-70 even when omitted in config" do
    Application.put_env(:nostr_relay, :relay_info, supported_nips: [1, 11, 42])
    Application.put_env(:nostr_relay, :nip29, enabled: false)

    metadata = RelayInfo.metadata()
    assert 13 in metadata["supported_nips"]
    assert 70 in metadata["supported_nips"]
  end

  test "publishes admin pubkey and relay self pubkey independently" do
    admin_pubkey = String.duplicate("a", 64)
    self_pub = String.duplicate("b", 64)

    Application.put_env(:nostr_relay, :relay_info, pubkey: admin_pubkey)
    Application.put_env(:nostr_relay, :relay_identity, self_pub: self_pub)

    metadata = RelayInfo.metadata()
    assert metadata["pubkey"] == admin_pubkey
    assert metadata["self"] == self_pub
  end

  test "serves configured NIP-11 optional fields" do
    relay_info = Application.get_env(:nostr_relay, :relay_info, [])

    limitation =
      relay_info
      |> Keyword.get(:limitation, %{})
      |> Map.put(:payment_required, true)

    Application.put_env(
      :nostr_relay,
      :relay_info,
      relay_info
      |> Keyword.put(:banner, "https://relay.example.com/banner.png")
      |> Keyword.put(:icon, "https://relay.example.com/icon.png")
      |> Keyword.put(:terms_of_service, "https://relay.example.com/tos.txt")
      |> Keyword.put(:payments_url, "https://relay.example.com/payments")
      |> Keyword.put(:fees, %{admission: [%{amount: 1000, unit: "msats"}]})
      |> Keyword.put(:limitation, limitation)
      |> Keyword.put(:supported_nips, [11])
    )

    Application.put_env(:nostr_relay, :auth, required: true)

    metadata = RelayInfo.metadata()

    assert metadata["banner"] == "https://relay.example.com/banner.png"
    assert metadata["icon"] == "https://relay.example.com/icon.png"
    assert metadata["terms_of_service"] == "https://relay.example.com/tos.txt"
    assert metadata["payments_url"] == "https://relay.example.com/payments"
    assert metadata["fees"] == %{"admission" => [%{"amount" => 1000, "unit" => "msats"}]}
    assert metadata["limitation"]["auth_required"] == true
    assert metadata["limitation"]["payment_required"] == true
    assert Map.has_key?(metadata["limitation"], "max_message_length")
    assert Map.has_key?(metadata["limitation"], "max_subscriptions")
    assert Map.has_key?(metadata["limitation"], "max_limit")
    assert Map.has_key?(metadata["limitation"], "max_subid_length")
    assert Map.has_key?(metadata["limitation"], "max_event_tags")
    assert Map.has_key?(metadata["limitation"], "max_content_length")
    assert Map.has_key?(metadata["limitation"], "min_pow_difficulty")
    assert Map.has_key?(metadata["limitation"], "restricted_writes")
    assert Map.has_key?(metadata["limitation"], "created_at_lower_limit")
    assert Map.has_key?(metadata["limitation"], "created_at_upper_limit")
    assert Map.has_key?(metadata["limitation"], "default_limit")
    refute Map.has_key?(metadata, "limits")

    refute Map.has_key?(metadata, "privacy_policy")
    refute Map.has_key?(metadata, "retention")
    refute Map.has_key?(metadata, "relay_countries")
    refute Map.has_key?(metadata, "language_tags")
    refute Map.has_key?(metadata, "posting_policy")
  end
end
