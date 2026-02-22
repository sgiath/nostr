import Config

config :nostr_relay,
  ecto_repos: [Nostr.Relay.Repo]

config :nostr_relay, :server,
  scheme: :http,
  websocket_options: [compress: false, max_frame_size: 8_000_000]

config :nostr_relay, Nostr.Relay.Repo, default_transaction_mode: :immediate

config :nostr_relay, :relay_info,
  name: "Nostr Relay",
  description: "General-purpose Nostr relay",
  banner: nil,
  icon: nil,
  pubkey: nil,
  contact: nil,
  terms_of_service: nil,
  software: "https://github.com/sgiath/nostr",
  version: "0.1.0",
  supported_nips: [1, 2, 4, 9, 11, 13, 17, 28, 40, 42, 45, 50, 59, 70],
  payments_url: nil,
  fees: nil,
  limitation: %{
    max_message_length: 8_000_000,
    max_subscriptions: 100,
    max_limit: 10_000,
    max_subid_length: 100,
    max_event_tags: 100,
    max_content_length: 8_192,
    min_pow_difficulty: 0,
    payment_required: false,
    restricted_writes: false,
    created_at_lower_limit: 31_536_000,
    created_at_upper_limit: 900,
    default_limit: 500
  }

config :nostr_relay, :relay_policy, min_prefix_length: 8

config :nostr_relay, :relay_identity,
  self_pub: nil,
  self_sec: nil

config :nostr_relay, :auth,
  required: false,
  mode: :none,
  timeout_seconds: 30,
  whitelist: [],
  denylist: []

config :nostr_relay, :nip29,
  enabled: false,
  allow_unmanaged_groups: true,
  publish_group_members: false,
  publish_group_roles: true,
  optional_checks: %{
    enforce_group_id_charset: false,
    enforce_previous_refs: false,
    min_previous_refs: 0,
    enforce_previous_known_events: false,
    enforce_late_publication: false,
    max_event_age_seconds: 86_400,
    require_invite_for_closed_groups: false
  },
  joins: %{
    auto_accept: false,
    allow_pending: true
  },
  roles: %{
    admin: [:put_user, :remove_user, :edit_metadata, :delete_event, :create_invite, :delete_group],
    moderator: [:delete_event]
  }

import_config "#{config_env()}.exs"
