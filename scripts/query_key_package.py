#!/usr/bin/env python3
"""Query a Nostr relay for a kind 443 KeyPackage from the given author.

Runs inside a python:3-slim container with the `websockets` package installed.
"""

import asyncio
import json
import os
import sys

import websockets

RELAY_URL = os.environ.get("RELAY_URL", "ws://nostr-relay:8080")
AUTHOR = os.environ.get("AUTHOR", "")
TIMEOUT = float(os.environ.get("TIMEOUT", "30"))

# Minimal bech32 implementation (public-domain reference).
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
GENERATOR = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]


def bech32_polymod(values):
    chk = 1
    for v in values:
        b = chk >> 25
        chk = (chk & 0x1FFFFFF) << 5 ^ v
        for i in range(5):
            chk ^= GENERATOR[i] if ((b >> i) & 1) else 0
    return chk


def bech32_hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]


def bech32_verify_checksum(hrp, data):
    return bech32_polymod(bech32_hrp_expand(hrp) + data) == 1


def bech32_convert_bits(data, from_bits, to_bits, pad=True):
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << to_bits) - 1
    max_acc = (1 << (from_bits + to_bits - 1)) - 1
    for value in data:
        if value < 0 or (value >> from_bits):
            return None
        acc = ((acc << from_bits) | value) & max_acc
        bits += from_bits
        while bits >= to_bits:
            bits -= to_bits
            ret.append((acc >> bits) & maxv)
    if pad:
        if bits:
            ret.append((acc << (to_bits - bits)) & maxv)
    elif bits >= from_bits or ((acc << (to_bits - bits)) & maxv):
        return None
    return ret


def bech32_decode(bech):
    if not bech:
        return None
    if (any(ord(x) < 33 or ord(x) > 126 for x in bech)) or (
        bech.lower() != bech and bech.upper() != bech
    ):
        return None
    bech = bech.lower()
    pos = bech.rfind("1")
    if pos < 1 or pos + 7 > len(bech) or len(bech) > 90:
        return None
    hrp = bech[:pos]
    data = [CHARSET.find(x) for x in bech[pos + 1 :]]
    if any(x < 0 for x in data):
        return None
    if not bech32_verify_checksum(hrp, data):
        return None
    decoded = bech32_convert_bits(data[:-6], 5, 8, False)
    return hrp, decoded


def normalize_pubkey(pubkey):
    if not pubkey:
        return None
    if pubkey.lower().startswith("npub"):
        hrp, decoded = bech32_decode(pubkey)
        if hrp == "npub" and decoded:
            return bytes(decoded).hex()
        return None
    if all(c in "0123456789abcdefABCDEF" for c in pubkey) and len(pubkey) == 64:
        return pubkey.lower()
    return None


async def main():
    author = normalize_pubkey(AUTHOR)
    if not author:
        print("invalid AUTHOR", file=sys.stderr)
        sys.exit(1)

    req_id = "kp-check"
    found = False
    try:
        async with websockets.connect(RELAY_URL) as ws:
            await ws.send(
                json.dumps(["REQ", req_id, {"kinds": [443], "authors": [author], "limit": 1}])
            )
            deadline = asyncio.get_event_loop().time() + TIMEOUT
            while asyncio.get_event_loop().time() < deadline:
                remaining = deadline - asyncio.get_event_loop().time()
                if remaining <= 0:
                    break
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=min(2.0, remaining))
                except asyncio.TimeoutError:
                    continue
                msg = json.loads(raw)
                if not isinstance(msg, list):
                    continue
                if len(msg) >= 3 and msg[0] == "EVENT" and msg[1] == req_id:
                    found = True
                    break
                if len(msg) >= 2 and msg[0] == "EOSE" and msg[1] == req_id:
                    break
    except websockets.exceptions.InvalidURI as exc:
        print(f"relay connection failed: {exc}", file=sys.stderr)
        sys.exit(1)
    except websockets.exceptions.ConnectionError as exc:
        print(f"relay connection failed: {exc}", file=sys.stderr)
        sys.exit(1)

    print(json.dumps({"found": found}))


if __name__ == "__main__":
    asyncio.run(main())
