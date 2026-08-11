#!/usr/bin/env python3
"""Derive a sandbox Nostr/Ethereum identity from a committed dev-world recipe.

Implements the derivation described by schemas/world-state.schema.json and
schemas/secrets-sidecar.schema.json:

  1. HKDF-SHA256 (RFC 5869) over the world's `devRootSeed` (IKM), `recipe`
     (salt), and `persona:<label>` (info) yields 32 bytes.
  2. Those bytes must be a valid secp256k1 scalar (nonzero, less than the
     curve order n). If not -- astronomically unlikely -- retry with info
     `persona:<label>:<counter>`, counter starting at 1.
  3. The 32 bytes ARE the Nostr secret key and, unmodified, the Ethereum
     private key: this is the existing covenant-gov/nostr-k-derivs scheme
     that scripts/derive-eth-address.py documents and reuses for the address
     side.
  4. `nsec` is the bech32 encoding (hrp `nsec`) of those 32 bytes.
  5. `npub` is the bech32 encoding (hrp `npub`) of the x-only public key --
     the 32-byte big-endian X coordinate of `secret * G` on secp256k1.
  6. The Ethereum address is produced by shelling out to
     scripts/derive-eth-address.py, so there is exactly one address scheme
     in this repo, not two.

Usage:
    scripts/derive-identity.py --root-seed <s> --recipe <id> --label <label> [--json]

Every derived identity is sandbox-only: the recipe travels with the
repository, so the keys it derives are public by construction.
"""
import argparse
import hashlib
import hmac
import subprocess
import sys
from pathlib import Path

# secp256k1 curve parameters (SEC 2).
P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B
G = (GX, GY)

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
GENERATOR = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]


def hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    """RFC 5869 HKDF-SHA256, extract then expand."""
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    okm = b""
    t = b""
    counter = 1
    while len(okm) < length:
        t = hmac.new(prk, t + info + bytes([counter]), hashlib.sha256).digest()
        okm += t
        counter += 1
    return okm[:length]


def is_valid_scalar(b: bytes) -> bool:
    """True when `b` is a nonzero 32-byte big-endian value less than n."""
    if len(b) != 32:
        return False
    value = int.from_bytes(b, "big")
    return 0 < value < N


def _inv_mod(a: int, m: int) -> int:
    return pow(a, m - 2, m)


def _point_add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        lam = (3 * x1 * x1) * _inv_mod(2 * y1, P) % P
    else:
        lam = (y2 - y1) * _inv_mod((x2 - x1) % P, P) % P
    x3 = (lam * lam - x1 - x2) % P
    y3 = (lam * (x1 - x3) - y1) % P
    return (x3, y3)


def point_mul(k: int, point=G):
    """Scalar multiplication on secp256k1, returning the affine point."""
    result = None
    addend = point
    while k:
        if k & 1:
            result = _point_add(result, addend)
        addend = _point_add(addend, addend)
        k >>= 1
    return result


def x_only_pubkey(secret: bytes) -> bytes:
    """32-byte big-endian X coordinate of secret * G."""
    x, _y = point_mul(int.from_bytes(secret, "big"))
    return x.to_bytes(32, "big")


def _polymod(values):
    chk = 1
    for v in values:
        b = chk >> 25
        chk = (chk & 0x1FFFFFF) << 5 ^ v
        for i in range(5):
            chk ^= GENERATOR[i] if (b >> i) & 1 else 0
    return chk


def _hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]


def _create_checksum(hrp, data):
    values = _hrp_expand(hrp) + data
    polymod = _polymod(values + [0, 0, 0, 0, 0, 0]) ^ 1
    return [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]


def _convert_bits(data, from_bits, to_bits, pad=True):
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << to_bits) - 1
    for value in data:
        if value < 0 or (from_bits < 8 and value >> from_bits):
            raise ValueError("invalid data")
        acc = ((acc << from_bits) | value) & ((1 << (from_bits + to_bits)) - 1)
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


def bech32_encode(hrp: str, data: bytes) -> str:
    """Encode `data` as bech32 with human-readable part `hrp`."""
    data5 = _convert_bits(list(data), 8, 5, True)
    checksum = _create_checksum(hrp, data5)
    combined = data5 + checksum
    return hrp + "1" + "".join(CHARSET[d] for d in combined)


def _derive_eth_address_script() -> Path:
    return Path(__file__).resolve().parent / "derive-eth-address.py"


def derive_eth_address(nsec: str) -> str:
    """Shell out to derive-eth-address.py -- the one address scheme."""
    script = _derive_eth_address_script()
    result = subprocess.run(
        [sys.executable, str(script), nsec],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"derive-eth-address.py failed (is 'cast' on PATH?): {result.stderr.strip()}"
        )
    return result.stdout.strip()


def derive(root_seed: str, recipe: str, label: str) -> dict:
    """Derive one identity for `label` under `recipe`, retrying on an invalid scalar."""
    ikm = root_seed.encode("utf-8")
    salt = recipe.encode("utf-8")
    counter = 0
    while True:
        info = f"persona:{label}".encode("utf-8")
        if counter:
            info = f"persona:{label}:{counter}".encode("utf-8")
        secret = hkdf_sha256(ikm, salt, info, 32)
        if is_valid_scalar(secret):
            break
        counter += 1

    nsec = bech32_encode("nsec", secret)
    npub = bech32_encode("npub", x_only_pubkey(secret))
    eth_address = derive_eth_address(nsec)
    return {
        "name": label,
        "npub": npub,
        "nsec": nsec,
        "ethAddress": eth_address,
        "ethPrivateKey": "0x" + secret.hex(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Derive a sandbox Nostr/Ethereum identity.")
    parser.add_argument("--root-seed", required=True, help="World devRootSeed")
    parser.add_argument("--recipe", required=True, help="Recipe id, e.g. pacto-dev-world/v1")
    parser.add_argument("--label", required=True, help="Persona label")
    parser.add_argument("--json", action="store_true", help="Emit a JSON object")
    args = parser.parse_args()

    try:
        identity = derive(args.root_seed, args.recipe, args.label)
    except Exception as exc:  # noqa: BLE001 -- surfaced to the caller, not swallowed
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.json:
        import json

        print(json.dumps(identity))
    else:
        for key in ("name", "npub", "nsec", "ethAddress", "ethPrivateKey"):
            print(f"{key}={identity[key]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
