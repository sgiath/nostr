# Repo TODO

## relay

- [ ] NIP-05 support (configure DNS verification as required, allow/deny domains)
- [ ] NIP-15 ???
- [ ] NIP-43 support
- [ ] Opt-in NIP-62 support
- [ ] Explore NIP-77
- [ ] Support NIP-86 (after NIP-98 is done)
- [ ] NIP-88: do not delete votes (kind 1018) and make backdated events configurable
- [ ] Explore NIP-BE
- [ ] NIP-11 limitation: enforce `payment_required` gate before relay actions
- [ ] NIP-11 limitation: enforce `restricted_writes` policy gate for EVENT acceptance
- [ ] move some administrative config to the database instead of config file
  - [ ] whitelist/blacklist pubkeys and IP addresses
  - [ ] NIP-29 relay groups admin interface
- [ ] implement pay-to-relay

## nostr-lib

- [ ] NIP-98 support

## relay admin

- [ ] admin interface for the relay

## personal manager

- [ ] client that displays all your events from relays and allows you to manage them
