defmodule Nostr.Relay.Web.RelayInfoTest do
  use ExUnit.Case, async: false

  alias Nostr.Relay.Web.RelayInfo

  setup do
    original_info = Application.get_env(:nostr_relay, :relay_info)
    original_identity = Application.get_env(:nostr_relay, :relay_identity)
    original_nip29 = Application.get_env(:nostr_relay, :nip29)

    on_exit(fn ->
      Application.put_env(:nostr_relay, :relay_info, original_info)
      Application.put_env(:nostr_relay, :relay_identity, original_identity)
      Application.put_env(:nostr_relay, :nip29, original_nip29)
    end)

    :ok
  end

  test "does not advertise NIP-29 when disabled" do
    Application.put_env(:nostr_relay, :relay_info, supported_nips: [1, 11, 42])
    Application.put_env(:nostr_relay, :nip29, enabled: false)

    metadata = RelayInfo.metadata()
    refute 29 in metadata["supported_nips"]
  end

  test "advertises NIP-29 when enabled" do
    Application.put_env(:nostr_relay, :relay_info, supported_nips: [1, 11, 42])
    Application.put_env(:nostr_relay, :nip29, enabled: true)

    metadata = RelayInfo.metadata()
    assert 29 in metadata["supported_nips"]
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
end
