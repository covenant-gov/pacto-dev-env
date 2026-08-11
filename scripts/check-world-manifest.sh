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

WORLD="${WORLD:-default}"

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
  local schema="$1" instance="$2" label="$3" output status
  if output="$(python3 "$SCRIPT_DIR/validate-json-schema.py" "$schema" "$instance" 2>&1)"; then
    pass "$label validates against $(basename "$schema")"
    return 0
  fi
  status=$?
  if [[ "$status" -eq 1 ]]; then
    fail "$label fails schema $(basename "$schema"):"
    while IFS= read -r line; do
      echo "      $line"
    done <<<"$output"
    return 1
  fi
  fail "$label: schema validator error (exit $status): $output"
  return 2
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

  local persona_names identity_names
  persona_names="$(jq -c '[.personas[].name]' "$manifest")"
  identity_names="$(jq -c '[.identities[].name]' "$sidecar")"
  if [[ "$persona_names" != "$identity_names" ]]; then
    fail "sidecar identities do not match manifest personas by name/order: personas=$persona_names identities=$identity_names"
    ok=0
  fi

  local mismatches
  mismatches="$(jq -r -s '
    (.[0].personas | map({(.name): {npub, ethAddress}}) | add // {}) as $m
    | (.[1].identities | map({(.name): {npub, ethAddress}}) | add // {}) as $s
    | [ ($m | keys[]) as $name
        | select($s[$name] == null or $m[$name] != $s[$name])
        | $name
      ] | join(", ")
  ' "$manifest" "$sidecar")"
  if [[ -n "$mismatches" ]]; then
    fail "npub/ethAddress mismatch between manifest and sidecar for persona(s): $mismatches"
    ok=0
  fi

  if [[ "$ok" -eq 1 ]]; then
    pass "cross-document invariants hold (version, recipe, identities)"
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

  if ! check_sidecar_mode "$sidecar"; then
    exit 1
  fi

  echo
  echo -e "${GREEN}World manifest for '$WORLD' is valid.${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
