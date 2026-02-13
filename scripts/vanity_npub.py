#!/usr/bin/env python3
"""Generate a vanity Nostr npub with a given bech32 prefix."""

import sys

from nostr_keys import BECH32_CHARSET, run_vanity_search


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <prefix>")
        print(f"Valid bech32 characters: {BECH32_CHARSET}")
        sys.exit(1)

    prefix = sys.argv[1].lower()

    if prefix.startswith("npub1"):
        prefix = prefix[5:]

    for ch in prefix:
        if ch not in BECH32_CHARSET:
            print(f"Error: '{ch}' is not a valid bech32 character.")
            print(f"Valid characters: {BECH32_CHARSET}")
            sys.exit(1)

    run_vanity_search(prefix, hex_mode=False)


if __name__ == "__main__":
    main()
