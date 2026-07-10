#!/usr/bin/env python3
"""Find a bot in pacto-bot-api.toml by hex or bech32 public key.

Prints JSON with "found", "bot_id", and "hex_pubkey".
"""

import json
import re
import sys

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


def parse_bots(config_path):
    bots = []
    current = {}
    in_bots = False
    with open(config_path) as handle:
        for line in handle:
            line = line.split("#")[0].strip()
            if line == "[[bots]]":
                if current:
                    bots.append(current)
                current = {}
                in_bots = True
                continue
            if not in_bots:
                continue
            match = re.match(r'^(\w+)\s*=\s*"(.*)"$', line)
            if match:
                current[match.group(1)] = match.group(2)
                continue
            match = re.match(r'^(\w+)\s*=\s*\[(.*)\]$', line)
            if match:
                current[match.group(1)] = [
                    x.strip().strip('"') for x in match.group(2).split(",") if x.strip()
                ]
                continue
            match = re.match(
                r'^(\w+)\s*=\s*\{\s*backend\s*=\s*"(\w+)"\s*,\s*nsec\s*=\s*"(.*)"\s*\}$',
                line,
            )
            if match:
                current["signing_backend"] = match.group(2)
                current["nsec"] = match.group(3)
    if current:
        bots.append(current)
    return bots


def main():
    if len(sys.argv) < 3:
        print("usage: find_bot_by_pubkey.py <config> <pubkey>", file=sys.stderr)
        sys.exit(1)
    config_path = sys.argv[1]
    pubkey = sys.argv[2]
    target_hex = normalize_pubkey(pubkey)
    if not target_hex:
        print(json.dumps({"found": False, "error": "invalid pubkey"}))
        sys.exit(1)

    bots = parse_bots(config_path)
    for bot in bots:
        bot_hex = normalize_pubkey(bot.get("npub", ""))
        if bot_hex and bot_hex == target_hex:
            print(
                json.dumps(
                    {"found": True, "bot_id": bot.get("id"), "hex_pubkey": bot_hex}
                )
            )
            return

    print(json.dumps({"found": False, "hex_pubkey": target_hex}))


if __name__ == "__main__":
    main()
