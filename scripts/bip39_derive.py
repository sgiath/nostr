#!/usr/bin/env python3
"""Derive a Nostr keypair from a BIP39 mnemonic (NIP-06).

Derivation path: m/44'/1237'/0'/0/0
"""

import sys

from embit import bip32, bip39
from mnemonic import Mnemonic

from nostr_keys import format_keypair, pubkey_from_privbytes


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <seed words...>")
        sys.exit(1)

    seed_phrase = " ".join(sys.argv[1:])

    mnemo = Mnemonic("english")
    if not mnemo.check(seed_phrase):
        print("Error: invalid BIP39 seed phrase (checksum failed).")
        sys.exit(1)

    seed = bip39.mnemonic_to_seed(seed_phrase)
    root = bip32.HDKey.from_seed(seed)
    child = root.derive("m/44h/1237h/0h/0/0")
    priv_bytes = child.key.serialize()

    pub_bytes = pubkey_from_privbytes(priv_bytes)
    format_keypair(priv_bytes, pub_bytes)


if __name__ == "__main__":
    main()
