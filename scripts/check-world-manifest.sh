#!/usr/bin/env bash
set -euo pipefail

# Validates a generated dev-world manifest and secret sidecar for WORLD
# (default: default).
#
# Two layers of checking:
#   1. Each file against its committed JSON Schema (schemas/*.schema.json),
#      via scripts/validate-json-schema.py.
#   2. Cross-document invariants a schema cannot express on its own: the
#      sidecar and manifest must agree on manifestVersion and recipe id,
#      every persona's derivation.recipe must match the manifest recipe id,
#      the sidecar must carry exactly one identity per persona (same names,
#      same order) with matching npub/ethAddress, and the sidecar file must
#      be owner-only (mode 0600).
#
# Exits nonzero at the first class of problem found: missing files, schema
# violations, cross-document mismatches, or a loose sidecar file mode.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }

# Prefer an already-exported WORLD over a value from .env.
_WORLD_FROM_ENV="${WORLD-}"
if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.env"
  set +a
fi
if [ -n "${_WORLD_FROM_ENV}" ]; then
  WORLD="$_WORLD_FROM_ENV"
fi
WORLD="${WORLD:-default}"
unset _WORLD_FROM_ENV

# manifestVersion window this checker accepts. Every consumer declares its
# own window; a manifest outside it is refused, never partially consumed.
MANIFEST_VERSION_MIN=1
MANIFEST_VERSION_MAX=1

# Returns 0 if $1 is a non-negative integer within the inclusive window
# [$2, $3], 1 otherwise (too low, too high, or not an integer at all).
version_in_window() {
  local version="$1" min="$2" max="$3"
  [[ "$version" =~ ^[0-9]+$ ]] || return 1
  (( version >= min && version <= max ))
}

# validate_schema <schema.json> <instance.json> <label>
# Prints one pass/fail line, plus one indented line per violation on
# failure. Returns 0 valid, 1 invalid, 2 validator error.
validate_schema() {
  local schema="$1" instance="$2" label="$3" output status=0
  output="$(python3 "$SCRIPT_DIR/validate-json-schema.py" "$schema" "$instance" 2>&1)" || status=$?
  if [[ "$status" -eq 0 ]]; then
    pass "$label validates against $(basename "$schema")"
    return 0
  elif [[ "$status" -eq 1 ]]; then
    fail "$label fails schema $(basename "$schema"):"
    while IFS= read -r line; do
      echo "      $line"
    done <<<"$output"
    return 1
  else
    fail "$label: schema validator error (exit $status): $output"
    return 2
  fi
}

# check_cross_document <manifest.json> <sidecar.json>
# Collects and reports every cross-document invariant violation before
# returning; returns 0 only if all invariants hold.
check_cross_document() {
  local manifest="$1" sidecar="$2" ok=1
  local m_version s_version m_recipe s_recipe

  m_version="$(jq -r '.manifestVersion' "$manifest")"
  s_version="$(jq -r '.manifestVersion' "$sidecar")"
  m_recipe="$(jq -r '.recipe.id' "$manifest")"
  s_recipe="$(jq -r '.recipe' "$sidecar")"

  if ! version_in_window "$m_version" "$MANIFEST_VERSION_MIN" "$MANIFEST_VERSION_MAX"; then
    fail "manifest manifestVersion ($m_version) is outside the accepted window [$MANIFEST_VERSION_MIN, $MANIFEST_VERSION_MAX]"
    ok=0
  fi

  if [[ "$m_version" != "$s_version" ]]; then
    fail "sidecar manifestVersion ($s_version) does not match manifest manifestVersion ($m_version)"
    ok=0
  fi

  if [[ "$m_recipe" != "$s_recipe" ]]; then
    fail "sidecar recipe ($s_recipe) does not match manifest recipe.id ($m_recipe)"
    ok=0
  fi

  local bad_derivations
  bad_derivations="$(jq -r --arg recipe "$m_recipe" \
    '[.personas[] | select(.derivation.recipe != $recipe) | .name] | join(", ")' "$manifest")"
  if [[ -n "$bad_derivations" ]]; then
    fail "persona(s) with derivation.recipe != manifest recipe.id: $bad_derivations"
    ok=0
  fi

  local persona_count persona_unique
  persona_count="$(jq -r '.personas | length' "$manifest")"
  persona_unique="$(jq -r '.personas | map(.name) | unique | length' "$manifest")"
  if [[ "$persona_count" != "$persona_unique" ]]; then
    fail "manifest has duplicate persona names"
    ok=0
  fi

  local identity_count identity_unique
  identity_count="$(jq -r '.identities | length' "$sidecar")"
  identity_unique="$(jq -r '.identities | map(.name) | unique | length' "$sidecar")"
  if [[ "$identity_count" != "$identity_unique" ]]; then
    fail "sidecar has duplicate identity names"
    ok=0
  fi

  local persona_names identity_names
  persona_names="$(jq -c '[.personas[].name]' "$manifest")"
  identity_names="$(jq -c '[.identities[].name]' "$sidecar")"
  if [[ "$persona_names" != "$identity_names" ]]; then
    fail "sidecar identities do not match manifest personas by name/order: personas=$persona_names identities=$identity_names"
    ok=0
  fi

  # Names/order are already verified equal above; compare npub/ethAddress
  # pairwise by index rather than collapsing into a name-keyed object,
  # which would silently drop entries when names collide (now rejected above).
  local mismatches
  mismatches="$(jq -r -s '
    (.[0].personas | map(.name)) as $names
    | (.[0].personas | map({npub, ethAddress})) as $m
    | (.[1].identities | map({npub, ethAddress})) as $s
    | [ range(0; $m | length)
        | select($s[.] == null or $m[.] != $s[.])
        | $names[.]
      ] | join(", ")
  ' "$manifest" "$sidecar")"
  if [[ -n "$mismatches" ]]; then
    fail "npub/ethAddress mismatch between manifest and sidecar for persona(s): $mismatches"
    ok=0
  fi

  if [[ "$ok" -eq 1 ]]; then
    pass "cross-document invariants hold (version, recipe, unique names, identities)"
    return 0
  fi
  return 1
}

# check_identity_correspondence <sidecar.json>
# Verifies each sidecar identity is cryptographically self-consistent: the
# nsec decodes to ethPrivateKey, the nsec's public key re-encodes to the
# recorded npub, and `cast wallet address` on the private key reproduces the
# recorded ethAddress. Catches a sidecar whose fields were hand-edited or
# copied from a different identity but still happen to pass schema checks.
check_identity_correspondence() {
  local sidecar="$1" output status=0
  output="$(SCRIPT_DIR="$SCRIPT_DIR" python3 - "$sidecar" <<'PYEOF' 2>&1
import importlib.util
import json
import os
import sys
from pathlib import Path

script_dir = Path(os.environ["SCRIPT_DIR"])
sidecar_path = Path(sys.argv[1])


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, script_dir / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


derive_identity = load_module("derive_identity", "derive-identity.py")
derive_eth = load_module("derive_eth_address", "derive-eth-address.py")

identities = json.loads(sidecar_path.read_text())["identities"]

problems = []
for identity in identities:
    name = identity["name"]
    nsec = identity["nsec"]
    npub = identity["npub"]
    eth_address = identity["ethAddress"]
    eth_private_key = identity["ethPrivateKey"]

    try:
        hex_key = derive_eth.decode_nsec_hex(nsec)
    except ValueError as exc:
        problems.append(f"{name}: invalid nsec: {exc}")
        continue

    expected_priv = "0x" + hex_key
    if eth_private_key.lower() != expected_priv.lower():
        problems.append(
            f"{name}: ethPrivateKey ({eth_private_key}) does not decode from nsec "
            f"(expected {expected_priv})"
        )

    recomputed_npub = derive_identity.bech32_encode(
        "npub", derive_identity.x_only_pubkey(bytes.fromhex(hex_key))
    )
    if recomputed_npub != npub:
        problems.append(
            f"{name}: npub ({npub}) does not correspond to nsec (expected {recomputed_npub})"
        )

    try:
        cast_address = derive_eth.derive_address(nsec)
    except RuntimeError as exc:
        problems.append(f"{name}: cast failed to derive address: {exc}")
        continue
    if cast_address.lower() != eth_address.lower():
        problems.append(
            f"{name}: ethAddress ({eth_address}) does not match cast-derived "
            f"address ({cast_address})"
        )

if problems:
    for p in problems:
        print(p)
    sys.exit(1)
PYEOF
  )" || status=$?

  if [[ "$status" -eq 0 ]]; then
    pass "sidecar identities cryptographically correspond (nsec -> npub/ethAddress/ethPrivateKey)"
    return 0
  fi
  fail "sidecar identity correspondence check failed:"
  while IFS= read -r line; do
    echo "      $line"
  done <<<"$output"
  return 1
}

# check_recipe_drift <manifest.json>
# Loads the committed worlds/$WORLD.world.json recipe (never regenerated)
# and verifies the manifest on disk still matches it: recipe id, cast
# persona names/order, relayEndpoint, chain.endpoint, chain.chainId. Catches
# a manifest left stale after the recipe file was edited.
check_recipe_drift() {
  local manifest="$1" recipe_file="$REPO_ROOT/worlds/$WORLD.world.json" ok=1

  if [[ ! -f "$recipe_file" ]]; then
    fail "recipe file not found: $recipe_file"
    return 1
  fi

  local r_recipe m_recipe r_names m_names
  r_recipe="$(jq -r '.recipe' "$recipe_file")"
  m_recipe="$(jq -r '.recipe.id' "$manifest")"
  if [[ "$r_recipe" != "$m_recipe" ]]; then
    fail "manifest recipe.id ($m_recipe) does not match $recipe_file recipe ($r_recipe)"
    ok=0
  fi

  r_names="$(jq -c '[.cast[].name]' "$recipe_file")"
  m_names="$(jq -c '[.personas[].name]' "$manifest")"
  if [[ "$r_names" != "$m_names" ]]; then
    fail "manifest personas do not match $recipe_file cast by name/order: cast=$r_names personas=$m_names"
    ok=0
  fi

  local r_relay m_relay
  r_relay="$(jq -r '.world.relayEndpoint' "$recipe_file")"
  m_relay="$(jq -r '.world.relayEndpoint' "$manifest")"
  if [[ "$r_relay" != "$m_relay" ]]; then
    fail "manifest world.relayEndpoint ($m_relay) does not match $recipe_file world.relayEndpoint ($r_relay)"
    ok=0
  fi

  local r_chain_endpoint m_chain_endpoint
  r_chain_endpoint="$(jq -r '.world.chain.endpoint' "$recipe_file")"
  m_chain_endpoint="$(jq -r '.world.chain.endpoint' "$manifest")"
  if [[ "$r_chain_endpoint" != "$m_chain_endpoint" ]]; then
    fail "manifest world.chain.endpoint ($m_chain_endpoint) does not match $recipe_file world.chain.endpoint ($r_chain_endpoint)"
    ok=0
  fi

  local r_chain_id m_chain_id
  r_chain_id="$(jq -r '.world.chain.chainId' "$recipe_file")"
  m_chain_id="$(jq -r '.world.chain.chainId' "$manifest")"
  if [[ "$r_chain_id" != "$m_chain_id" ]]; then
    fail "manifest world.chain.chainId ($m_chain_id) does not match $recipe_file world.chain.chainId ($r_chain_id)"
    ok=0
  fi

  if [[ "$ok" -eq 1 ]]; then
    pass "manifest matches committed recipe $recipe_file (id, cast, relay, chain)"
    return 0
  fi
  return 1
}

# check_sidecar_mode <sidecar.json>
# The secret sidecar must be readable/writable by its owner only. Rejects
# any permission bit exposed to group or other. `stat` flags differ between
# macOS/BSD (-f '%Lp') and Linux/GNU (-c '%a'); try both.
check_sidecar_mode() {
  local sidecar="$1" mode
  if ! mode="$(stat -f '%Lp' "$sidecar" 2>/dev/null)"; then
    if ! mode="$(stat -c '%a' "$sidecar" 2>/dev/null)"; then
      fail "could not stat file mode of $sidecar"
      return 1
    fi
  fi

  if (( (8#$mode & 8#077) != 0 )); then
    warn "sidecar file mode is $mode, expected 0600 (tighten with: chmod 600 \"$sidecar\")"
    return 1
  fi

  pass "sidecar file mode is $mode (owner-only)"
  return 0
}

main() {
  echo "Pacto world manifest verification (WORLD=$WORLD)"
  echo "=================================================="

  if ! command -v jq >/dev/null 2>&1; then
    fail "jq is required but not found in PATH"
    exit 1
  fi

  if ! command -v cast >/dev/null 2>&1; then
    fail "cast (foundry) is required but not found in PATH"
    exit 1
  fi

  local manifest="$REPO_ROOT/data/world/$WORLD/world-state.json"
  local sidecar="$REPO_ROOT/data/world/$WORLD/world-secrets.json"

  if [[ ! -f "$manifest" || ! -f "$sidecar" ]]; then
    fail "generated world files not found for WORLD=$WORLD; run 'make world-manifest' first"
    exit 1
  fi

  if ! validate_schema "$REPO_ROOT/schemas/world-state.schema.json" "$manifest" "manifest"; then
    exit 1
  fi
  if ! validate_schema "$REPO_ROOT/schemas/secrets-sidecar.schema.json" "$sidecar" "sidecar"; then
    exit 1
  fi

  if ! check_cross_document "$manifest" "$sidecar"; then
    exit 1
  fi

  if ! check_identity_correspondence "$sidecar"; then
    exit 1
  fi

  if ! check_recipe_drift "$manifest"; then
    exit 1
  fi

  if ! check_sidecar_mode "$sidecar"; then
    exit 1
  fi

  echo
  echo -e "${GREEN}World manifest for '$WORLD' is valid.${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
