"""Shared Nostr key utilities."""

import multiprocessing
import os
import time

from nostr_tools import to_bech32
from secp256k1 import PrivateKey as SecpPrivateKey

BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def pubkey_from_privbytes(priv_bytes: bytes) -> bytes:
    """Derive x-only public key (32 bytes) from private key bytes."""
    priv = SecpPrivateKey(priv_bytes)
    return priv.pubkey.serialize(compressed=True)[1:]


def format_keypair(priv_bytes: bytes, pub_bytes: bytes):
    """Print a keypair in hex and bech32 formats."""
    npub = to_bech32("npub", pub_bytes.hex())
    nsec = to_bech32("nsec", priv_bytes.hex())
    print(f"Private key (hex):    {priv_bytes.hex()}")
    print(f"Private key (bech32): {nsec}")
    print(f"Public key (hex):     {pub_bytes.hex()}")
    print(f"Public key (bech32):  {npub}")


def _vanity_worker(prefix, hex_mode, counter, lock, found_event, result_queue):
    """Worker process for parallel vanity search."""
    local_count = 0
    while not found_event.is_set():
        priv_bytes = os.urandom(32)
        pub_bytes = pubkey_from_privbytes(priv_bytes)
        local_count += 1

        if hex_mode:
            match = pub_bytes.hex().startswith(prefix)
        else:
            npub = to_bech32("npub", pub_bytes.hex())
            match = npub[5:].startswith(prefix)

        if local_count % 1000 == 0:
            with lock:
                counter.value += 1000

        if match:
            with lock:
                counter.value += local_count % 1000
            result_queue.put((priv_bytes, pub_bytes))
            found_event.set()
            return


def run_vanity_search(prefix: str, hex_mode: bool):
    """Run a parallel vanity key search and print the result."""
    n_workers = multiprocessing.cpu_count()
    label = prefix if hex_mode else f"npub1{prefix}"
    print(f"Searching for {label}... using {n_workers} workers")

    counter = multiprocessing.Value("L", 0)
    lock = multiprocessing.Lock()
    found_event = multiprocessing.Event()
    result_queue = multiprocessing.Queue()

    workers = []
    for _ in range(n_workers):
        p = multiprocessing.Process(
            target=_vanity_worker,
            args=(prefix, hex_mode, counter, lock, found_event, result_queue),
        )
        p.start()
        workers.append(p)

    t0 = time.monotonic()
    while not found_event.is_set():
        time.sleep(1)
        elapsed = time.monotonic() - t0
        with lock:
            total = counter.value
        rate = total / elapsed if elapsed > 0 else 0
        print(
            f"\r  {total:,} attempts | {rate:,.0f}/sec | {elapsed:.0f}s",
            end="",
            flush=True,
        )

    priv_bytes, pub_bytes = result_queue.get(timeout=2)
    for p in workers:
        p.terminate()
        p.join()

    print()
    print(f"Found after {counter.value:,} total attempts")
    format_keypair(priv_bytes, pub_bytes)
