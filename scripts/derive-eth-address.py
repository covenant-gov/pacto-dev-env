#!/usr/bin/env python3
"""Derive an Ethereum address from a Nostr nsec (bech32-encoded secret key).

This matches the derivation used by the covenant-gov/nostr-k-derivs Rust crate:
the Nostr private key bytes are used directly as the Ethereum private key, and
the standard secp256k1 -> Keccak-256 -> last-20-bytes address is produced.

Usage:
    scripts/derive-eth-address.py nsec1...

The script exits non-zero if the argument is not a valid nsec or if `cast` is
not available on PATH.
"""
import subprocess
import sys

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
GENERATOR = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]


def _polymod(values):
    chk = 1
    for v in values:
        b = chk >> 25
        chk = (chk & 0x1ffffff) << 5 ^ v
        for i in range(5):
            chk ^= GENERATOR[i] if (b >> i) & 1 else 0
    return chk


def _hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]


def _verify_checksum(hrp, data):
    return _polymod(_hrp_expand(hrp) + data) == 1


def _convert_bits(data, from_bits, to_bits, pad=True):
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << to_bits) - 1
    max_acc = (1 << (from_bits + to_bits - 1)) - 1
    for value in data:
        if value < 0 or (from_bits < 8 and value >> from_bits):
            raise ValueError("invalid data")
        acc = ((acc << from_bits) | value) & max_acc
        bits += from_bits
        while bits >= to_bits:
            bits -= to_bits
            ret.append((acc >> bits) & maxv)
    if pad:
        if bits:
            ret.append((acc << (to_bits - bits)) & maxv)
    elif bits >= from_bits or ((acc << (to_bits - bits)) & maxv):
        raise ValueError("invalid padding")
    return ret


def decode_nsec_hex(nsec):
    if not (nsec and nsec.lower() == nsec):
        raise ValueError("nsec must be lowercase bech32")
    if nsec[:4] != "nsec":
        raise ValueError("string does not start with 'nsec'")
    pos = nsec.rfind("1")
    if pos < 1 or pos + 7 > len(nsec):
        raise ValueError("invalid bech32 separator position")
    hrp = nsec[:pos]
    data = [CHARSET.find(c) for c in nsec[pos + 1:]]
    if any(c == -1 for c in data):
        raise ValueError("invalid bech32 character")
    if not _verify_checksum(hrp, data):
        raise ValueError("invalid bech32 checksum")
    payload = _convert_bits(data[:-6], 5, 8, False)
    if len(payload) != 32:
        raise ValueError(f"expected 32-byte secret, got {len(payload)}")
    return bytes(payload).hex()


def derive_address(nsec):
    hex_key = decode_nsec_hex(nsec)
    result = subprocess.run(
        ["cast", "wallet", "address", "--private-key", f"0x{hex_key}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"cast failed: {result.stderr.strip()}")
    return result.stdout.strip()


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <nsec>", file=sys.stderr)
        return 1
    try:
        print(derive_address(sys.argv[1].strip()))
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
