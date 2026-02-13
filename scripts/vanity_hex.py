#!/usr/bin/env python3
"""Generate a vanity Nostr key with a given hex prefix."""

import sys

from nostr_keys import run_vanity_search


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <hex-prefix>")
        print("Valid characters: 0123456789abcdef")
        sys.exit(1)

    prefix = sys.argv[1].lower()

    try:
        int(prefix, 16)
    except ValueError:
        print(f"Error: '{prefix}' is not a valid hex prefix.")
        print("Valid characters: 0123456789abcdef")
        sys.exit(1)

    run_vanity_search(prefix, hex_mode=True)


if __name__ == "__main__":
    main()
