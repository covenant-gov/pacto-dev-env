#!/usr/bin/env bash
set -euo pipefail

# World-state derivation test suite.
#
# Exercises scripts/derive-identity.py's math (HKDF, secp256k1, bech32) and
# scripts/generate-world-manifest.sh's end-to-end behavior: determinism,
# file permissions, and refusal on a missing world file. No Docker, no
# network -- everything here runs against the local filesystem.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

failed=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; failed=1; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }

DERIVE="$REPO_ROOT/scripts/derive-identity.py"
ETH_SCRIPT="$REPO_ROOT/scripts/derive-eth-address.py"
GENERATE="$REPO_ROOT/scripts/generate-world-manifest.sh"

TMP_DIR="$(mktemp -d)"
CLEANUP_DATA_DIRS=()

cleanup() {
  rm -rf "$TMP_DIR"
  local d
  for d in "${CLEANUP_DATA_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

# Portable octal file mode: BSD stat (macOS) first, then GNU stat (Linux).
file_mode() {
  local mode
  if ! mode="$(stat -f '%OLp' "$1" 2>/dev/null)"; then
    if ! mode="$(stat -c '%a' "$1" 2>/dev/null)"; then
      return 1
    fi
  fi
  printf '%s' "$mode"
}

ROOT_SEED="test-root-seed-for-world-derivation"
RECIPE="pacto-dev-world/v1"

check_determinism() {
  echo "Checking determinism of same recipe + label..."
  local a b
  a=$(python3 "$DERIVE" --root-seed "$ROOT_SEED" --recipe "$RECIPE" --label bosun --json)
  b=$(python3 "$DERIVE" --root-seed "$ROOT_SEED" --recipe "$RECIPE" --label bosun --json)
  if [ "$a" = "$b" ]; then
    pass "same recipe + label produce the same npub and ETH address across runs"
  else
    fail "same recipe + label produced different output across runs"
  fi
}

check_label_sensitivity() {
  echo "Checking label sensitivity..."
  local a b
  a=$(python3 "$DERIVE" --root-seed "$ROOT_SEED" --recipe "$RECIPE" --label bosun --json)
  b=$(python3 "$DERIVE" --root-seed "$ROOT_SEED" --recipe "$RECIPE" --label captain --json)
  if [ "$a" != "$b" ]; then
    pass "two different labels produce different identities"
  else
    fail "different labels produced identical identities"
  fi
}

check_recipe_sensitivity() {
  echo "Checking recipe (salt) sensitivity..."
  local a b
  a=$(python3 "$DERIVE" --root-seed "$ROOT_SEED" --recipe "$RECIPE" --label bosun --json)
  b=$(python3 "$DERIVE" --root-seed "$ROOT_SEED" --recipe "pacto-dev-world/v2" --label bosun --json)
  if [ "$a" != "$b" ]; then
    pass "a different recipe id with the same label produces a different identity"
  else
    fail "different recipe id produced an identical identity"
  fi
}

check_is_valid_scalar() {
  echo "Checking is_valid_scalar boundary behavior..."
  local result
  result=$(python3 - "$DERIVE" <<'PYEOF'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("derive_identity", sys.argv[1])
di = importlib.util.module_from_spec(spec)
spec.loader.exec_module(di)

zero = bytes(32)
at_order = di.N.to_bytes(32, "big")  # == n, must be rejected: valid range is < n
normal = (1).to_bytes(32, "big")

print("zero", di.is_valid_scalar(zero))
print("at_order", di.is_valid_scalar(at_order))
print("normal", di.is_valid_scalar(normal))
PYEOF
)
  if echo "$result" | grep -q "^zero False$"; then
    pass "is_valid_scalar rejects 32 zero bytes"
  else
    fail "is_valid_scalar did not reject 32 zero bytes"
  fi
  if echo "$result" | grep -q "^at_order False$"; then
    pass "is_valid_scalar rejects a value >= the curve order n"
  else
    fail "is_valid_scalar did not reject a value >= the curve order n"
  fi
  if echo "$result" | grep -q "^normal True$"; then
    pass "is_valid_scalar accepts a normal key"
  else
    fail "is_valid_scalar rejected a normal key"
  fi
}

check_bech32_roundtrip() {
  echo "Checking bech32 nsec round-trip against the existing decoder..."
  local result
  result=$(python3 - "$DERIVE" "$ETH_SCRIPT" <<'PYEOF'
import importlib.util, sys

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

di = load("derive_identity", sys.argv[1])
dea = load("derive_eth_address", sys.argv[2])

secret = di.hkdf_sha256(b"seed", b"salt", b"info", 32)
nsec = di.bech32_encode("nsec", secret)
decoded = dea.decode_nsec_hex(nsec)
print("ok" if decoded == secret.hex() else f"mismatch:{decoded}")
PYEOF
)
  if [ "$result" = "ok" ]; then
    pass "a generated nsec round-trips through decode_nsec_hex"
  else
    fail "nsec round-trip through decode_nsec_hex failed ($result)"
  fi
}

check_known_answer() {
  echo "Checking secp256k1 known-answer vectors and curve equation..."
  local result k1_expected k2_expected
  k1_expected="79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
  k2_expected="c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
  result=$(python3 - "$DERIVE" <<'PYEOF'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("derive_identity", sys.argv[1])
di = importlib.util.module_from_spec(spec)
spec.loader.exec_module(di)

on_curve = (di.GY * di.GY - di.GX ** 3 - 7) % di.P == 0
print("curve_ok", on_curve)

print("k1", di.x_only_pubkey((1).to_bytes(32, "big")).hex())
print("k2", di.x_only_pubkey((2).to_bytes(32, "big")).hex())
PYEOF
)
  if echo "$result" | grep -q "^curve_ok True$"; then
    pass "generator point satisfies y^2 = x^3 + 7 (mod p)"
  else
    fail "generator point does not satisfy the curve equation (got: $result)"
  fi
  if echo "$result" | grep -q "^k1 $k1_expected$"; then
    pass "secret key 0x01 yields the generator point's X coordinate"
  else
    fail "secret key 0x01 did not yield the expected X coordinate (got: $result)"
  fi
  if echo "$result" | grep -q "^k2 $k2_expected$"; then
    pass "secret key 0x02 yields the doubled point's (2G) X coordinate"
  else
    fail "secret key 0x02 did not yield the expected X coordinate (got: $result)"
  fi
}

check_bip39_golden_vector() {
  echo "Checking BIP-39 entropy-to-mnemonic against the canonical all-zero vector..."
  local expected="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
  local result
  result=$(python3 - "$DERIVE" <<'PYEOF'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("derive_identity", sys.argv[1])
di = importlib.util.module_from_spec(spec)
spec.loader.exec_module(di)

print(di.entropy_to_mnemonic(bytes(16)))
PYEOF
)
  if [ "$result" = "$expected" ]; then
    pass "16 zero bytes of entropy produce the canonical 'abandon...about' mnemonic"
  else
    fail "expected '$expected', got '$result'"
  fi
}

check_bip44_eth_golden_vector() {
  echo "Checking BIP-32 m/44'/60'/0'/0/0 against the canonical Foundry/cast address..."
  local expected="0x9858EfFD232B4033E47d90003D41EC34EcaEda94"
  local result
  result=$(python3 - "$DERIVE" <<'PYEOF'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("derive_identity", sys.argv[1])
di = importlib.util.module_from_spec(spec)
spec.loader.exec_module(di)

mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
seed = di.bip39_seed(mnemonic)
eth_secret = di._bip32_derive_path(seed, di.EVM_PATH)
print(di._eth.address_from_private_key_hex(eth_secret.hex()))
PYEOF
)
  if [ "$result" = "$expected" ]; then
    pass "abandon...about at m/44'/60'/0'/0/0 matches the well-known Foundry/cast vector ($expected)"
  else
    fail "expected '$expected', got '$result' -- this is the same vector pacto-app pins in evm_keys.rs"
  fi
}

check_cast_cross_check() {
  echo "Cross-checking a real derived persona's EVM address against 'cast wallet address --mnemonic'..."
  if ! command -v cast >/dev/null 2>&1; then
    warn "cast not found on PATH; skipping live cross-check"
    return
  fi
  local identity mnemonic derived_addr cast_addr
  identity=$(python3 "$DERIVE" --root-seed "$ROOT_SEED" --recipe "$RECIPE" --label bosun --json)
  mnemonic=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['mnemonic'])" "$identity")
  derived_addr=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['ethAddress'])" "$identity")
  cast_addr=$(cast wallet address --mnemonic "$mnemonic")
  if [ "$derived_addr" = "$cast_addr" ]; then
    pass "derived ethAddress ($derived_addr) matches 'cast wallet address --mnemonic' for the same phrase"
  else
    fail "derived ethAddress ($derived_addr) disagrees with cast ($cast_addr) for phrase '$mnemonic'"
  fi
}

check_nostr_sdk_cross_check() {
  echo "Checking npub against nostr-sdk's own NIP-06 derivation (requires cargo)..."
  if ! command -v cargo >/dev/null 2>&1; then
    warn "cargo not found on PATH; skipping live nostr-sdk cross-check"
    return
  fi
  local identity mnemonic derived_npub project_dir sdk_npub
  identity=$(python3 "$DERIVE" --root-seed "$ROOT_SEED" --recipe "$RECIPE" --label bosun --json)
  mnemonic=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['mnemonic'])" "$identity")
  derived_npub=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['npub'])" "$identity")

  project_dir="$TMP_DIR/nip06check"
  mkdir -p "$project_dir/src"
  cat >"$project_dir/Cargo.toml" <<CARGOEOF
[package]
name = "nip06check"
version = "0.1.0"
edition = "2021"

[dependencies]
nostr-sdk = { version = "0.44.1", features = ["nip06"] }
CARGOEOF
  cat >"$project_dir/src/main.rs" <<RSEOF
use nostr_sdk::prelude::*;
fn main() {
    let phrase = std::env::args().nth(1).expect("phrase arg");
    let keys = Keys::from_mnemonic(phrase, None).expect("derive");
    println!("{}", keys.public_key().to_bech32().unwrap());
}
RSEOF
  if sdk_npub=$(cd "$project_dir" && cargo run --quiet -- "$mnemonic" 2>/dev/null); then
    if [ "$derived_npub" = "$sdk_npub" ]; then
      pass "derived npub ($derived_npub) matches nostr-sdk's Keys::from_mnemonic for the same phrase"
    else
      fail "derived npub ($derived_npub) disagrees with nostr-sdk ($sdk_npub) for the same phrase"
    fi
  else
    warn "could not build/run the throwaway nostr-sdk cross-check project; skipping"
  fi
  rm -rf "$project_dir"
}

check_generator_e2e_determinism() {
  echo "Checking generate-world-manifest.sh idempotence for WORLD=default..."
  local manifest="$REPO_ROOT/data/world/default/world-state.json"
  local sidecar="$REPO_ROOT/data/world/default/world-secrets.json"
  local m1="$TMP_DIR/m1.json" m2="$TMP_DIR/m2.json"
  local s1="$TMP_DIR/s1.json" s2="$TMP_DIR/s2.json"

  if ! WORLD=default "$GENERATE" >/dev/null; then
    fail "first generate-world-manifest.sh run failed"
    return
  fi
  cp "$manifest" "$m1"
  cp "$sidecar" "$s1"

  if ! WORLD=default "$GENERATE" >/dev/null; then
    fail "second generate-world-manifest.sh run failed"
    return
  fi
  cp "$manifest" "$m2"
  cp "$sidecar" "$s2"

  if diff -q "$m1" "$m2" >/dev/null; then
    pass "world-state.json is byte-identical across two runs"
  else
    fail "world-state.json differs between runs"
  fi

  if diff -q "$s1" "$s2" >/dev/null; then
    pass "world-secrets.json is byte-identical across two runs"
  else
    fail "world-secrets.json differs between runs"
  fi

  local manifest_mode sidecar_mode
  manifest_mode=$(file_mode "$manifest")
  sidecar_mode=$(file_mode "$sidecar")

  if [ "$manifest_mode" = "644" ]; then
    pass "world-state.json is mode 0644"
  else
    fail "world-state.json is mode $manifest_mode, expected 644"
  fi

  if [ "$sidecar_mode" = "600" ]; then
    pass "world-secrets.json is mode 0600"
  else
    fail "world-secrets.json is mode $sidecar_mode, expected 600"
  fi

  local persona_count sandbox_only_count
  persona_count=$(python3 -c "import json; print(len(json.load(open('$manifest'))['personas']))")
  sandbox_only_count=$(python3 -c "
import json
d = json.load(open('$manifest'))
print(sum(1 for p in d['personas'] if p.get('sandboxOnly') is True))
")
  if [ "$persona_count" -gt 0 ] && [ "$sandbox_only_count" = "$persona_count" ]; then
    pass "every persona ($persona_count) carries sandboxOnly: true"
  else
    fail "only $sandbox_only_count of $persona_count personas carry sandboxOnly: true"
  fi

  local identity_count mnemonic_word_ok_count
  identity_count=$(python3 -c "import json; print(len(json.load(open('$sidecar'))['identities']))")
  mnemonic_word_ok_count=$(python3 -c "
import json
d = json.load(open('$sidecar'))
print(sum(1 for i in d['identities'] if len(i.get('mnemonic', '').split()) == 12))
")
  if [ "$identity_count" -gt 0 ] && [ "$mnemonic_word_ok_count" = "$identity_count" ]; then
    pass "every identity ($identity_count) carries a 12-word mnemonic"
  else
    fail "only $mnemonic_word_ok_count of $identity_count identities carry a 12-word mnemonic"
  fi

  if grep -qiE "mnemonic|nsec1|PrivateKey" "$manifest"; then
    fail "world-state.json (public manifest) leaks signing material (mnemonic/nsec/private key)"
  else
    pass "world-state.json contains no mnemonic, nsec, or private key"
  fi

  if git -C "$REPO_ROOT" check-ignore -q "$sidecar"; then
    pass "world-secrets.json is still gitignored after regeneration"
  else
    fail "world-secrets.json is not gitignored after regeneration"
  fi
}

check_missing_world_file() {
  echo "Checking refusal against a missing world file..."
  local missing_world="tw-missing-$$"
  local output status
  set +e
  output=$(WORLD="$missing_world" "$GENERATE" 2>&1)
  status=$?
  set -e
  CLEANUP_DATA_DIRS+=("$REPO_ROOT/data/world/$missing_world")
  if [ "$status" -ne 0 ] && echo "$output" | grep -q "$missing_world.world.json"; then
    pass "generation against a missing world file exits nonzero and names the missing file"
  else
    fail "missing world file did not refuse correctly (status=$status): $output"
  fi
}

main() {
  echo "World-state derivation test suite"
  echo "=================================="

  check_determinism
  check_label_sensitivity
  check_recipe_sensitivity
  check_is_valid_scalar
  check_bech32_roundtrip
  check_known_answer
  check_bip39_golden_vector
  check_bip44_eth_golden_vector
  check_cast_cross_check
  check_nostr_sdk_cross_check
  check_generator_e2e_determinism
  check_missing_world_file

  echo
  if [ "$failed" -eq 0 ]; then
    echo -e "${GREEN}All checks passed.${NC}"
    exit 0
  else
    echo -e "${RED}Some checks failed.${NC}"
    exit 1
  fi
}

main "$@"
