---
name: Nostr Army Knife
description: The Nostr Army Knife is a powerful command-line tool for interacting with the Nostr protocol. It allows you to query relays, create and publish events, manage keys, encode/decode identifiers, encrypt messages, and more.
---

Use `nak` to interact with the Nostr protocol from the command line: query relays, create and publish events, manage keys, encode/decode identifiers, encrypt messages, and more.

All output is JSON (one event per line) unless otherwise noted. Pipe through `jq` for formatting/filtering.

## When to Use

- User wants to query, publish, or manage Nostr events
- User needs to encode/decode nip19 entities (npub, nsec, nevent, naddr, nprofile, note)
- User wants to manage Nostr keypairs
- User wants to interact with Nostr relays
- User asks about Nostr protocol details or NIPs
- User wants to encrypt/decrypt messages, gift-wrap events, or use bunker signing
- User wants to sync events between relays, upload files via Blossom, or manage NIP-29 groups

## Key Concepts

### Nostr Event Format (NIP-01)

Every piece of data in Nostr is a signed JSON event:

```json
{
  "id": "<32-byte hex sha256 of serialized event>",
  "pubkey": "<32-byte hex public key>",
  "created_at": 1234567890,
  "kind": 1,
  "tags": [["e", "<event-id>"], ["p", "<pubkey>"]],
  "content": "hello world",
  "sig": "<64-byte hex schnorr signature>"
}
```

### Common Event Kinds

| Kind | Description | NIP |
|------|-------------|-----|
| 0 | User metadata (profile) | NIP-01 |
| 1 | Short text note | NIP-01 |
| 3 | Follow list | NIP-02 |
| 4 | Encrypted DM (deprecated) | NIP-04 |
| 5 | Deletion request | NIP-09 |
| 6 | Repost | NIP-18 |
| 7 | Reaction | NIP-25 |
| 1059 | Gift wrap | NIP-59 |
| 1111 | Comment | NIP-22 |
| 1222 | Audio note | -- |
| 9735 | Zap receipt | NIP-57 |
| 10002 | Relay list | NIP-65 |
| 30023 | Long-form content | NIP-23 |
| 31922 | Date-based calendar event | NIP-52 |
| 31923 | Time-based calendar event | NIP-52 |
| 30617 | Git repository | NIP-34 |

Kinds 30000-39999 are parameterized replaceable events (NIP-33): identified by `kind` + `pubkey` + `d` tag. Publishing a new event with the same triplet replaces the old one.

### NIP-19 Identifiers

| Prefix | Contains | Example Use |
|--------|----------|-------------|
| `npub1` | Public key | Identify a user |
| `nsec1` | Secret key | Sign events (keep secret) |
| `note1` | Event ID | Reference a specific event |
| `nevent1` | Event ID + relay hints + author | Fetchable event reference |
| `nprofile1` | Pubkey + relay hints | Fetchable profile reference |
| `naddr1` | Kind + pubkey + d-tag + relays | Reference replaceable events |

### Relay URLs

Relay arguments can be given as bare hostnames (`nos.lol`), full URLs (`wss://nos.lol`), or with trailing slashes. nak normalizes them automatically.

### Secret Key Formats

The `--sec` flag (and `$NOSTR_SECRET_KEY` env var) accepts:
- 64-char hex string
- `nsec1...` bech32-encoded key
- `ncryptsec1...` NIP-49 password-encrypted key (will prompt for password)
- `bunker://...` NIP-46 remote signing URL

---

## Commands Reference

### `nak event` -- Create and Publish Events

Generates a signed Nostr event. Prints to stdout; also publishes if relay URLs are given as arguments.

```bash
# Minimal event (kind 1, default content, signed with key "01")
nak event

# Custom content, publish to relays
nak event -c 'hello world' wss://nos.lol wss://relay.damus.io

# Specific kind with tags
nak event -k 1 -c 'good morning' --tag t=gm --sec <hex-or-nsec>

# Replaceable event with d-tag
nak event -k 30023 -c '# My Article' -d my-article-slug --sec $NOSTR_SECRET_KEY relay.example.com

# Set timestamp (natural language or unix)
nak event -c 'backdated' --ts 'two weeks ago'
nak event -c 'specific time' --ts 1698632644

# Multi-value tags (semicolon-separated)
nak event -t 'e=<event-id>;wss://relay.com;root' -t 'p=<pubkey>;wss://relay.com'

# Proof of Work
nak event -c 'hello' --pow 24

# Protected event (NIP-70)
nak event -t '-' -c 'protected content'

# Pipe an existing event (or partial) through, optionally modifying and republishing
echo '{"tags": [["t", "spam"]]}' | nak event -c 'tagged content'
echo '<full-event-json>' | nak event wss://other-relay.com

# Ask for confirmation before publishing
nak event -c 'important post' --confirm wss://nos.lol

# Print nevent code after publishing
nak event -c 'hello' --nevent wss://nos.lol
```

**Key flags:**
- `-c, --content` -- event content (prefix with `@` to read from file: `-c @file.md`)
- `-k, --kind` -- event kind (default: 1)
- `-t, --tag` -- add tag: `-t key=value` or `-t key=v1;v2;v3` for multi-value
- `-e`, `-p`, `-d` -- shortcuts for `--tag e=`, `--tag p=`, `--tag d=`
- `--ts, --created-at` -- timestamp (unix or natural language like `'two weeks ago'`)
- `--sec` -- signing key (hex, nsec, ncryptsec, or bunker URL)
- `--pow` -- NIP-13 proof-of-work difficulty target
- `--envelope` -- wrap output in `["EVENT", ...]` relay message format
- `--auth` -- auto-authenticate with NIP-42 if relay requires it

### `nak publish` -- Quick Note Publishing

Reads content from stdin. Handles mention parsing, hashtag extraction, URL detection, and relay routing automatically.

```bash
# Simple note
echo "hello world" | nak publish

# Reply to an event
echo "I agree!" | nak publish --reply nevent1...

# With extra tags
echo "tagged post" | nak publish -t t=mytag

# Confirm before sending
echo "important" | nak publish --confirm
```

`publish` auto-processes content: turns `npub1...` into `nostr:npub1...` URIs, extracts `#hashtags`, converts bare domains to URLs, adds `p`/`q` tags for mentions, and routes to the right write/read relays.

### `nak req` -- Query Relays

Sends NIP-01 REQ filters to relays. Without relay args, prints the filter JSON.

```bash
# Print filter without querying
nak req -k 1 -l 10

# Query relays for kind 1 events
nak req -k 1 -l 15 wss://nos.lol wss://nostr.wine

# By author
nak req -k 0 -a <pubkey-hex> wss://nos.lol

# By event ID
nak req -i <event-id-hex> wss://relay.damus.io

# By tag
nak req -k 1 -t t=nostr wss://nos.lol

# Time range (natural language or unix)
nak req -k 1 --since '2024-01-01' --until '2024-01-31' -l 100 wss://nos.lol

# Full-text search (NIP-50, relay must support it)
nak req -k 1 --search 'nostr army knife' wss://relay.nostr.band

# Stream new events (keep subscription open)
nak req -k 1 --stream wss://nos.lol

# Paginate to get more events than relay limit allows
nak req -k 1 --limit 50000 --paginate --paginate-interval 2s wss://nos.lol

# Fetch only IDs (NIP-77)
nak req -k 1 -a <pubkey> --ids-only wss://nos.lol

# Use outbox model to auto-discover relays for given pubkeys
nak req -k 1 -a <pubkey> --outbox

# Pipe filter from stdin
echo '{"kinds": [1], "#t": ["test"]}' | nak req -l 5 wss://nos.lol

# Fetch only events missing from a local file (negentropy sync)
nak req --only-missing ./events.jsonl -k 30617 pyramid.fiatjaf.com
```

**Key flags:**
- `-k, --kind` -- filter by kind (repeatable)
- `-a, --author` -- filter by author pubkey (repeatable)
- `-i, --id` -- filter by event ID (repeatable)
- `-t, --tag` -- filter by tag (repeatable)
- `-l, --limit` -- max events to return
- `-s, --since` -- events newer than timestamp
- `-u, --until` -- events older than timestamp
- `--search` -- NIP-50 full-text search
- `--stream` -- keep subscription open after EOSE
- `--paginate` -- auto-paginate to bypass relay limits
- `--bare` -- print raw filter JSON (not wrapped in `["REQ", ...]`)
- `--auth` -- NIP-42 authentication
- `--outbox` -- use outbox relay discovery

### `nak fetch` -- Fetch by NIP-19/NIP-05 Reference

Resolves nip19 codes or nip05 identifiers and fetches the referenced events using embedded relay hints and outbox discovery.

```bash
# Fetch event by nevent code
nak fetch nevent1qqs...

# Fetch profile by npub
nak fetch npub1...

# Fetch by nip05 identifier
nak fetch user@example.com

# Add extra relays
nak fetch --relay wss://relay.nostr.band npub1...

# Pipe nip19 codes
echo npub1... | nak fetch
```

### `nak count` -- Count Events

Like `req` but uses NIP-45 COUNT. HyperLogLog aggregation when multiple relays given.

```bash
# Count kind 1 events by an author
nak count -k 1 -a <pubkey> wss://nos.lol

# Count events with a tag
nak count -k 1 -t t=nostr wss://relay.nostr.band
```

### `nak filter` -- Test Event Against Filter

Checks if an event matches a filter locally (no relay needed). Outputs the event if it matches, nothing if it doesn't.

```bash
# Check if event matches kind filter
echo '{"kind": 1, "content": "hello"}' | nak filter -k 1

# Combine CLI flags with a base filter
nak filter '{"kind": 1, "content": "hello"}' '{"kinds": [1]}' -k 0
```

---

### `nak key` -- Key Management

```bash
# Generate a new private key (hex)
nak key generate

# Derive public key from private key
nak key public <hex-private-key>

# Encrypt private key with password (NIP-49)
nak key encrypt <hex-private-key> <password>

# Decrypt ncryptsec to hex
nak key decrypt <ncryptsec> <password>

# Combine pubkeys with musig2
nak key combine <pubkey1> <pubkey2>
```

### `nak encode` -- Encode to NIP-19

```bash
# Encode pubkey to npub
nak encode npub <pubkey-hex>

# Encode private key to nsec
nak encode nsec <privkey-hex>

# Encode event ID to nevent with relay hints
nak encode nevent --relay wss://nos.lol --author <pubkey> <event-id>

# Encode profile with relay hints
nak encode nprofile --relay wss://nos.lol <pubkey-hex>

# Encode addressable event reference
nak encode naddr --kind 30023 --author <pubkey> --relay wss://nos.lol -d <d-tag-value>

# Auto-detect from JSON on stdin
echo '{"pubkey":"<hex>","relays":["wss://nos.lol"]}' | nak encode
```

### `nak decode` -- Decode NIP-19/NIP-05/Hex

```bash
# Decode any nip19 entity
nak decode npub1...
nak decode nevent1...
nak decode naddr1...
nak decode nsec1...

# Extract just the event ID
nak decode -e nevent1...

# Extract just the pubkey
nak decode -p nprofile1...

# Decode nip05 identifier
nak decode user@example.com
```

---

### `nak encrypt` / `nak decrypt` -- NIP-44 Encryption

```bash
# Encrypt plaintext to a recipient (NIP-44)
nak encrypt --sec <sender-sec> -p <recipient-pubkey> 'secret message'

# Decrypt ciphertext from a sender (NIP-44)
nak decrypt --sec <recipient-sec> -p <sender-pubkey> <base64-ciphertext>

# Use legacy NIP-04 encryption
nak encrypt --nip04 --sec <sec> -p <pubkey> 'message'
nak decrypt --nip04 --sec <sec> -p <pubkey> <ciphertext>
```

### `nak gift` -- NIP-59 Gift Wrapping

Wraps an event in encrypted gift-wrap for private delivery.

```bash
# Gift-wrap an event to a recipient
nak event -c 'secret message' | nak gift wrap --sec <my-sec> -p <recipient-pubkey> | nak event wss://dmrelay.com

# Unwrap a gift-wrap event
nak req -p <my-pubkey> -k 1059 relay.com | nak gift unwrap --sec <my-sec> --from <sender-pubkey>
```

### `nak dekey` -- NIP-4E Decoupled Encryption Keys

Manages decoupled encryption keys for multi-device setups.

```bash
nak dekey --sec <sec>
nak dekey --sec <sec> --rotate  # create new key, invalidate old
```

---

### `nak relay` -- Relay Information

```bash
# Get relay information document (NIP-11)
nak relay wss://nos.lol
```

### `nak admin` -- Relay Management (NIP-86)

```bash
# Allow a pubkey on a relay
nak admin allowpubkey --sec <admin-sec> --pubkey <pubkey> relay.example.com

# Ban a pubkey
nak admin banpubkey --sec <admin-sec> --pubkey <pubkey> --reason "spam" relay.example.com

# List allowed pubkeys
nak admin listallowedpubkeys --sec <admin-sec> relay.example.com

# Change relay metadata
nak admin changerelayname --sec <admin-sec> --name "My Relay" relay.example.com
nak admin changerelaydescription --sec <admin-sec> --description "A personal relay" relay.example.com

# Manage event moderation
nak admin listeventsneedingmoderation --sec <admin-sec> relay.example.com
nak admin allowevent --sec <admin-sec> --id <event-id> relay.example.com
nak admin banevent --sec <admin-sec> --id <event-id> relay.example.com

# Manage allowed kinds
nak admin allowkind --sec <admin-sec> --kind 1 relay.example.com
nak admin disallowkind --sec <admin-sec> --kind 1 relay.example.com

# Block IPs
nak admin blockip --sec <admin-sec> --ip 1.2.3.4 --reason "abuse" relay.example.com
```

### `nak serve` -- Local Test Relay

```bash
# Start empty in-memory relay
nak serve

# With custom port and pre-loaded events
nak serve --port 8080 --events ./events.jsonl

# Enable negentropy (NIP-77) sync support
nak serve --negentropy

# Enable Blossom media server
nak serve --blossom

# Enable Grasp server
nak serve --grasp
```

Default: `ws://localhost:10547`

### `nak sync` -- Relay-to-Relay Sync

Uses NIP-77 negentropy to efficiently sync events between two relays.

```bash
# Sync all events
nak sync relay1.com relay2.com

# Sync specific kinds/authors
nak sync -k 1 -a <pubkey> relay1.com relay2.com
```

---

### `nak verify` -- Verify Event Signatures

```bash
# Pipe event JSON; outputs nothing on success, error message on failure
echo '<event-json>' | nak verify
```

### `nak nip` -- NIP Reference

```bash
# List all NIPs
nak nip

# Show details for a specific NIP
nak nip 01
nak nip 52

# Open NIP page in browser
nak nip open 29
```

---

### `nak blossom` -- Media Server (Blossom Protocol)

```bash
# Upload a file
nak blossom --server blossom.example.com --sec <sec> upload image.png

# Download a file
nak blossom --server blossom.example.com download <sha256-hash> -o output.png

# List blobs for a pubkey
nak blossom --server blossom.example.com list <pubkey>

# Delete a file
nak blossom --server blossom.example.com --sec <sec> delete <sha256-hash>

# Check if server has files
nak blossom --server blossom.example.com check <hash1> <hash2>

# Mirror between servers
nak blossom --server target.com --sec <sec> mirror --from source.com <sha256-hash>
```

### `nak wallet` -- NIP-60 Cashu Wallet

```bash
# Show wallet balance
nak wallet --sec <sec>

# List tokens
nak wallet --sec <sec> tokens

# Manage mints
nak wallet --sec <sec> mints

# Receive a cashu token
nak wallet --sec <sec> receive cashuA1...

# Send sats (prints cashu token)
nak wallet --sec <sec> send 100

# Pay a Lightning invoice
nak wallet --sec <sec> pay lnbc1...

# Send a NIP-61 nutzap
nak wallet --sec <sec> nutzap <npub-or-nevent>
```

### `nak bunker` -- NIP-46 Remote Signer

```bash
# Start a bunker daemon
nak bunker --sec <sec> -k <authorized-client-pubkey> relay.damus.io nos.lol

# With QR code display
nak bunker --sec <sec> --qrcode relay.damus.io

# Persistent bunker (saves config to disk)
nak bunker --persist --sec <sec> relay.damus.io

# Restart persistent bunker (no flags needed)
nak bunker --persist

# Named profile
nak bunker --profile myself --sec <sec> relay.damus.io

# Connect to a running bunker (client-initiated)
nak bunker connect 'nostrconnect://...'
```

### `nak group` -- NIP-29 Groups

```bash
# Group info
nak group info --sec <sec> relay.com'group-id

# Chat messages
nak group chat --sec <sec> relay.com'group-id

# Forum posts
nak group forum --sec <sec> relay.com'group-id

# Members and admins
nak group members relay.com'group-id
nak group admins relay.com'group-id

# Manage users
nak group put-user --sec <sec> relay.com'group-id --pubkey <pk>
nak group remove-user --sec <sec> relay.com'group-id --pubkey <pk>

# Edit group metadata
nak group edit-metadata --sec <sec> relay.com'group-id --name "New Name"

# Create invite
nak group create-invite --sec <sec> relay.com'group-id
```

Group identifiers use the format `relay.com'group-id` (relay URL, apostrophe, group identifier).

### `nak git` -- NIP-34 Git Operations

```bash
# Initialize a nip34 repository
nak git init

# Clone from nostr
nak git clone nostr://<naddr1...>

# Push/pull/fetch
nak git push
nak git pull
nak git fetch

# Check status
nak git status

# Sync metadata with relays
nak git sync
```

### `nak curl` -- HTTP with NIP-98 Auth

Makes HTTP requests with a NIP-98 authorization header.

```bash
nak curl --sec <sec> https://api.example.com/protected-endpoint
```

### `nak outbox` -- Outbox Relay Database

```bash
# List known outbox relays for a pubkey
nak outbox list <pubkey>
```

---

## Common Patterns

### Fetch a user's profile

```bash
nak req -k 0 -a <pubkey-hex> wss://nos.lol | jq '.content | fromjson'
```

### Get a user's latest notes

```bash
nak req -k 1 -a <pubkey-hex> -l 20 wss://nos.lol | jq -r .content
```

### Republish an event to other relays

```bash
nak req -i <event-id> wss://source-relay.com | nak event wss://target1.com wss://target2.com
```

### Decode a nip19 code, add relay hint, re-encode

```bash
nak decode note1... | jq -r .id | nak encode nevent -r wss://nos.lol
```

### Download events to a file

```bash
nak req -k 1 -a <pubkey> -l 1000 --paginate wss://nos.lol > events.jsonl
```

### Record and publish an audio note

```bash
ffmpeg -f alsa -i default -f webm -t 00:00:03 pipe:1 \
  | nak blossom --server blossom.primal.net upload \
  | jq -rc '{content: .url}' \
  | nak event -k 1222 --sec <sec> wss://nos.lol
```

### Extract all mentioned event IDs from someone's posts

```bash
nak req -k 1 -a <pubkey> -l 10 wss://relay.damus.io \
  | jq -r '.content | match("nostr:((note1|nevent1)[a-z0-9]+)";"g") | .captures[0].string' \
  | nak decode \
  | jq -r .id
```

---

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `NOSTR_SECRET_KEY` | Default signing key (hex, nsec, ncryptsec, or bunker URL) |
| `NOSTR_CLIENT_KEY` | Client identity key for NIP-46 bunker communication |

## Global Flags

| Flag | Effect |
|------|--------|
| `-q, --quiet` | Suppress stderr logs; `-qq` also suppresses stdout |
| `-v, --verbose` | Extra debug output |

## Tips

- All events print as one JSON object per line (JSONL). Use `jq` for formatting.
- Relay URLs are normalized: `nos.lol` becomes `wss://nos.lol`.
- Timestamps accept natural language: `'two weeks ago'`, `'December 31 2023'`, `'yesterday'`.
- Tag values with multiple entries use semicolons: `-t 'e=id;relay;marker'`.
- The `-t '-'` flag adds a NIP-70 protection tag.
- Pipe events between commands: `nak req ... | nak event <other-relays>` to republish.
- Use `--bare` with `nak req` to get raw filter JSON for scripting.
- `nak event` reads partial events from stdin and merges with CLI flags, then re-signs.
