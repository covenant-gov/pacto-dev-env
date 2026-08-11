#!/usr/bin/env python3
"""Derive a sandbox Nostr/Ethereum identity from a committed dev-world recipe.

Implements the derivation described by schemas/world-state.schema.json and
schemas/secrets-sidecar.schema.json:

  1. HKDF-SHA256 (RFC 5869) over the world's `devRootSeed` (IKM), `recipe`
     (salt), and `persona:<label>` (info) yields 16 bytes of BIP-39 entropy.
     This is the reproducibility contract: same root seed + recipe + label
     always yields the same identity.
  2. Those 16 bytes (128 bits) become a 12-word BIP-39 English mnemonic:
     append the first 4 bits of SHA-256(entropy) as a checksum, split the
     132-bit result into eleven-bit groups, and index scripts/bip39-english.txt.
  3. The mnemonic is the root of the identity, exactly as pacto-app treats a
     recovery phrase: `PBKDF2-HMAC-SHA512(mnemonic, "mnemonic", 2048)` yields
     a 64-byte BIP-39 seed (empty passphrase, matching
     `Keys::from_mnemonic(phrase, None)`).
  4. BIP-32 (hardened + normal child key derivation) over that seed derives:
       - the Nostr key at m/44'/1237'/0'/0/0 (NIP-06, what nostr_sdk's
         `Keys::from_mnemonic` uses)
       - the Ethereum key at m/44'/60'/0'/0/0 (pacto-app's
         `derive_eth_bip44_v1_from_mnemonic_phrase`)
     If a derivation step ever produces an out-of-range key (astronomically
     unlikely -- see BIP-32), retry from step 1 with info
     `persona:<label>:<counter>`, counter starting at 1.
  5. `nsec`/`npub` are the bech32 encoding (hrp `nsec`/`npub`) of the Nostr
     secret key and the 32-byte big-endian X coordinate of its public point.
  6. The Ethereum address is produced by shelling out to
     scripts/derive-eth-address.py's `address_from_private_key_hex`, so
     there is exactly one address scheme in this repo, not two.

Usage:
    scripts/derive-identity.py --root-seed <s> --recipe <id> --label <label> [--json]

Every derived identity is sandbox-only: the recipe travels with the
repository, so the keys it derives are public by construction.
"""
import argparse
import hashlib
import hmac
import importlib.util
import sys
import unicodedata
from pathlib import Path

# secp256k1 curve parameters (SEC 2).
P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
G = (GX, GY)
assert (GY * GY - GX ** 3 - 7) % P == 0, "secp256k1 G is off-curve"

# BIP-44 derivation paths this identity contract pins.
NOSTR_PATH = "m/44'/1237'/0'/0/0"  # NIP-06
EVM_PATH = "m/44'/60'/0'/0/0"  # pacto-app's phrase-derived v1 EVM key


def _load_module(name: str, path: Path):
    """Load a sibling script as a module (mirrors test/world-derivation.test.sh)."""
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_eth = _load_module("derive_eth_address", Path(__file__).resolve().parent / "derive-eth-address.py")

# Reuse the bech32 constants/helpers from derive-eth-address.py -- one implementation, not two.
CHARSET = _eth.CHARSET
GENERATOR = _eth.GENERATOR
_polymod = _eth._polymod
_hrp_expand = _eth._hrp_expand
_convert_bits = _eth._convert_bits

WORDLIST = (Path(__file__).resolve().parent / "bip39-english.txt").read_text().splitlines()
assert len(WORDLIST) == 2048, f"BIP-39 English wordlist must have 2048 entries, got {len(WORDLIST)}"


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


def _compressed_pubkey(k: int) -> bytes:
    """33-byte SEC1 compressed public key for private scalar `k`."""
    x, y = point_mul(k)
    prefix = 2 if y % 2 == 0 else 3
    return bytes([prefix]) + x.to_bytes(32, "big")


def _create_checksum(hrp, data):
    values = _hrp_expand(hrp) + data
    polymod = _polymod(values + [0, 0, 0, 0, 0, 0]) ^ 1
    return [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]


def bech32_encode(hrp: str, data: bytes) -> str:
    """Encode `data` as bech32 with human-readable part `hrp`."""
    data5 = _convert_bits(list(data), 8, 5, True)
    checksum = _create_checksum(hrp, data5)
    combined = data5 + checksum
    return hrp + "1" + "".join(CHARSET[d] for d in combined)


def entropy_to_mnemonic(entropy: bytes) -> str:
    """BIP-39 entropy -> mnemonic: append a checksum, split into 11-bit word indices."""
    checksum_bits = len(entropy) * 8 // 32
    checksum = hashlib.sha256(entropy).digest()
    bits = "".join(f"{b:08b}" for b in entropy)
    bits += "".join(f"{b:08b}" for b in checksum)[:checksum_bits]
    return " ".join(WORDLIST[int(bits[i:i + 11], 2)] for i in range(0, len(bits), 11))


def bip39_seed(mnemonic: str) -> bytes:
    """BIP-39 seed: PBKDF2-HMAC-SHA512 of the NFKD mnemonic, salt "mnemonic" (empty passphrase)."""
    normalized = unicodedata.normalize("NFKD", mnemonic).encode("utf-8")
    return hashlib.pbkdf2_hmac("sha512", normalized, b"mnemonic", 2048)


def _bip32_master(seed: bytes):
    """BIP-32 master key from a seed: HMAC-SHA512(key="Bitcoin seed", seed)."""
    digest = hmac.new(b"Bitcoin seed", seed, hashlib.sha512).digest()
    k = int.from_bytes(digest[:32], "big")
    if not (0 < k < N):
        raise ValueError("invalid master key: IL out of range")
    return k, digest[32:]


def _bip32_ckd_priv(k: int, chain_code: bytes, index: int):
    """BIP-32 private parent -> private child. `index >= 2**31` is hardened."""
    if index & 0x80000000:
        data = b"\x00" + k.to_bytes(32, "big") + index.to_bytes(4, "big")
    else:
        data = _compressed_pubkey(k) + index.to_bytes(4, "big")
    digest = hmac.new(chain_code, data, hashlib.sha512).digest()
    il = int.from_bytes(digest[:32], "big")
    if il >= N:
        raise ValueError("invalid child key: IL out of range")
    child_k = (il + k) % N
    if child_k == 0:
        raise ValueError("invalid child key: zero")
    return child_k, digest[32:]


def _bip32_derive_path(seed: bytes, path: str) -> bytes:
    """Derive the 32-byte private key at `path` (e.g. m/44'/1237'/0'/0/0)."""
    k, chain_code = _bip32_master(seed)
    for component in path.split("/"):
        if component == "m":
            continue
        hardened = component.endswith("'")
        index = int(component[:-1] if hardened else component)
        if hardened:
            index += 0x80000000
        k, chain_code = _bip32_ckd_priv(k, chain_code, index)
    return k.to_bytes(32, "big")


def derive(root_seed: str, recipe: str, label: str) -> dict:
    """Derive one identity for `label` under `recipe`, retrying on an invalid derivation."""
    ikm = root_seed.encode("utf-8")
    salt = recipe.encode("utf-8")
    counter = 0
    while True:
        info = f"persona:{label}".encode("utf-8")
        if counter:
            info = f"persona:{label}:{counter}".encode("utf-8")
        entropy = hkdf_sha256(ikm, salt, info, 16)
        mnemonic = entropy_to_mnemonic(entropy)
        seed = bip39_seed(mnemonic)
        try:
            nostr_secret = _bip32_derive_path(seed, NOSTR_PATH)
            eth_secret = _bip32_derive_path(seed, EVM_PATH)
            if not is_valid_scalar(nostr_secret) or not is_valid_scalar(eth_secret):
                raise ValueError("derived scalar out of range")
            break
        except ValueError:
            counter += 1

    nsec = bech32_encode("nsec", nostr_secret)
    npub = bech32_encode("npub", x_only_pubkey(nostr_secret))
    eth_address = _eth.address_from_private_key_hex(eth_secret.hex())
    return {
        "name": label,
        "mnemonic": mnemonic,
        "npub": npub,
        "nsec": nsec,
        "ethAddress": eth_address,
        "ethPrivateKey": "0x" + eth_secret.hex(),
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
        for key in ("name", "mnemonic", "npub", "nsec", "ethAddress", "ethPrivateKey"):
            print(f"{key}={identity[key]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
