#!/usr/bin/env bash
set -euo pipefail

# Standalone schema + cross-document test suite for the world-state
# manifest and secret sidecar. No Docker, no network, and no dependency on
# scripts/generate-world-manifest.sh having run: every fixture below is
# hand-built.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

failed=0
pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; failed=1; }

VALIDATE="$REPO_ROOT/scripts/validate-json-schema.py"
WS_SCHEMA="$REPO_ROOT/schemas/world-state.schema.json"
SS_SCHEMA="$REPO_ROOT/schemas/secrets-sidecar.schema.json"
CHECK_SCRIPT="$REPO_ROOT/scripts/check-world-manifest.sh"

TMPDIR="$(mktemp -d)"
FIXTURE_WORLD_DIRS=()
FIXTURE_WORLD_FILES=()
cleanup() {
  rm -rf "$TMPDIR"
  local dir file
  for dir in "${FIXTURE_WORLD_DIRS[@]:-}"; do
    [[ -n "$dir" ]] && rm -rf "$dir"
  done
  for file in "${FIXTURE_WORLD_FILES[@]:-}"; do
    [[ -n "$file" ]] && rm -f "$file"
  done
  return 0
}
trap cleanup EXIT

# Pattern-valid (charset-correct) but not checksum-valid bech32 bodies; the
# schemas only assert the character-class pattern, never the checksum.
CHARSET="qpzry9x8gf2tvdw0s3jn54khce6mua7l"
NPUB_TAIL="$(printf '%s' "${CHARSET}${CHARSET}" | cut -c1-58)"
HEXCHARS="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
ETH40="$(printf '%s' "$HEXCHARS" | cut -c1-40)"
HEX64="$(printf '%s' "$HEXCHARS" | cut -c1-64)"
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

valid_manifest() {
  cat <<JSON
{
  "manifestVersion": 1,
  "recipe": { "id": "pacto-dev-world/v1", "public": true },
  "world": {
    "name": "default",
    "relayEndpoint": "wss://localhost:7001",
    "chain": { "endpoint": "http://localhost:8545", "chainId": 31337 }
  },
  "personas": [
    {
      "name": "bosun",
      "role": "steward",
      "npub": "npub1${NPUB_TAIL}",
      "ethAddress": "0x${ETH40}",
      "botId": "bosun",
      "squadRole": "admin",
      "derivation": { "recipe": "pacto-dev-world/v1", "label": "bosun" },
      "sandboxOnly": true
    }
  ]
}
JSON
}

valid_sidecar() {
  cat <<JSON
{
  "manifestVersion": 1,
  "recipe": "pacto-dev-world/v1",
  "identities": [
    {
      "name": "bosun",
      "mnemonic": "${MNEMONIC}",
      "npub": "npub1${NPUB_TAIL}",
      "nsec": "nsec1${NPUB_TAIL}",
      "ethAddress": "0x${ETH40}",
      "ethPrivateKey": "0x${HEX64}",
      "sandboxOnly": true
    }
  ]
}
JSON
}

# run_validate <schema> <instance> — sets LAST_STATUS and LAST_OUTPUT.
run_validate() {
  local schema="$1" instance="$2"
  if LAST_OUTPUT="$(python3 "$VALIDATE" "$schema" "$instance" 2>&1)"; then
    LAST_STATUS=0
  else
    LAST_STATUS=$?
  fi
}

case_valid_manifest() {
  local f="$TMPDIR/valid-manifest.json"
  valid_manifest >"$f"
  run_validate "$WS_SCHEMA" "$f"
  if [[ "$LAST_STATUS" -eq 0 ]]; then
    pass "valid minimal manifest passes schema validation"
  else
    fail "valid minimal manifest should pass: $LAST_OUTPUT"
  fi
}

case_missing_required_field() {
  local f="$TMPDIR/missing-world.json"
  valid_manifest | jq 'del(.world)' >"$f"
  run_validate "$WS_SCHEMA" "$f"
  if [[ "$LAST_STATUS" -eq 1 ]] && grep -q '^world:' <<<"$LAST_OUTPUT"; then
    pass "manifest missing required 'world' field fails and names the field"
  else
    fail "expected exit 1 naming 'world', got exit $LAST_STATUS: $LAST_OUTPUT"
  fi
}

case_version_window() {
  local output
  output="$(
    # shellcheck disable=SC1090
    source "$CHECK_SCRIPT"
    version_in_window 1 "$MANIFEST_VERSION_MIN" "$MANIFEST_VERSION_MAX" && echo "ACCEPT:1" || echo "REJECT:1"
    version_in_window 0 "$MANIFEST_VERSION_MIN" "$MANIFEST_VERSION_MAX" && echo "ACCEPT:0" || echo "REJECT:0"
    version_in_window 2 "$MANIFEST_VERSION_MIN" "$MANIFEST_VERSION_MAX" && echo "ACCEPT:2" || echo "REJECT:2"
  )"
  if grep -q '^ACCEPT:1$' <<<"$output" && grep -q '^REJECT:0$' <<<"$output" && grep -q '^REJECT:2$' <<<"$output"; then
    pass "version_in_window accepts 1 and rejects both too-low (0) and too-high (2) for window [1,1]"
  else
    fail "version_in_window window check misbehaved: $output"
  fi
}

case_sandbox_only_false() {
  local f="$TMPDIR/sandbox-false.json"
  valid_manifest | jq '.personas[0].sandboxOnly = false' >"$f"
  run_validate "$WS_SCHEMA" "$f"
  if [[ "$LAST_STATUS" -eq 1 ]] && grep -q 'sandboxOnly' <<<"$LAST_OUTPUT"; then
    pass "persona with sandboxOnly:false fails validation"
  else
    fail "expected sandboxOnly:false to fail: exit $LAST_STATUS, output: $LAST_OUTPUT"
  fi
}

case_sandbox_only_omitted() {
  local f="$TMPDIR/sandbox-omitted.json"
  valid_manifest | jq 'del(.personas[0].sandboxOnly)' >"$f"
  run_validate "$WS_SCHEMA" "$f"
  if [[ "$LAST_STATUS" -eq 1 ]] && grep -q 'sandboxOnly' <<<"$LAST_OUTPUT"; then
    pass "persona with sandboxOnly omitted fails validation (R25 cannot be dodged by omission)"
  else
    fail "expected omitted sandboxOnly to fail: exit $LAST_STATUS, output: $LAST_OUTPUT"
  fi
}

case_additional_property() {
  local f="$TMPDIR/extra-prop.json"
  valid_manifest | jq '. + {"unexpectedField": true}' >"$f"
  run_validate "$WS_SCHEMA" "$f"
  if [[ "$LAST_STATUS" -eq 1 ]] && grep -q 'unexpectedField' <<<"$LAST_OUTPUT"; then
    pass "unknown top-level property fails additionalProperties:false"
  else
    fail "expected unexpectedField rejection: exit $LAST_STATUS, output: $LAST_OUTPUT"
  fi
}

case_malformed_npub() {
  local f="$TMPDIR/bad-npub.json"
  valid_manifest | jq '.personas[0].npub = "nsec1notarealnpubvalue"' >"$f"
  run_validate "$WS_SCHEMA" "$f"
  if [[ "$LAST_STATUS" -eq 1 ]] && grep -q 'npub' <<<"$LAST_OUTPUT"; then
    pass "malformed npub (wrong prefix/length/charset) fails pattern"
  else
    fail "expected malformed npub rejection: exit $LAST_STATUS, output: $LAST_OUTPUT"
  fi
}

case_malformed_eth_address() {
  local f="$TMPDIR/bad-eth.json"
  valid_manifest | jq '.personas[0].ethAddress = "deadbeef"' >"$f"
  run_validate "$WS_SCHEMA" "$f"
  if [[ "$LAST_STATUS" -eq 1 ]] && grep -q 'ethAddress' <<<"$LAST_OUTPUT"; then
    pass "malformed ethAddress (missing 0x, wrong length) fails pattern"
  else
    fail "expected malformed ethAddress rejection: exit $LAST_STATUS, output: $LAST_OUTPUT"
  fi
}

case_enum_role() {
  local f="$TMPDIR/bad-role.json"
  valid_manifest | jq '.personas[0].role = "overlord"' >"$f"
  run_validate "$WS_SCHEMA" "$f"
  if [[ "$LAST_STATUS" -eq 1 ]] && grep -q 'role' <<<"$LAST_OUTPUT"; then
    pass "invalid role enum value fails"
  else
    fail "expected role enum rejection: exit $LAST_STATUS, output: $LAST_OUTPUT"
  fi
}

case_enum_squad_role() {
  local f="$TMPDIR/bad-squadrole.json"
  valid_manifest | jq '.personas[0].squadRole = "emperor"' >"$f"
  run_validate "$WS_SCHEMA" "$f"
  if [[ "$LAST_STATUS" -eq 1 ]] && grep -q 'squadRole' <<<"$LAST_OUTPUT"; then
    pass "invalid squadRole enum value fails"
  else
    fail "expected squadRole enum rejection: exit $LAST_STATUS, output: $LAST_OUTPUT"
  fi
}

case_empty_personas() {
  local f="$TMPDIR/empty-personas.json"
  valid_manifest | jq '.personas = []' >"$f"
  run_validate "$WS_SCHEMA" "$f"
  if [[ "$LAST_STATUS" -eq 1 ]] && grep -q 'personas' <<<"$LAST_OUTPUT"; then
    pass "empty personas array fails minItems"
  else
    fail "expected empty personas rejection: exit $LAST_STATUS, output: $LAST_OUTPUT"
  fi
}

case_boolean_for_integer() {
  local f="$TMPDIR/bool-version.json"
  valid_manifest | jq '.manifestVersion = true' >"$f"
  run_validate "$WS_SCHEMA" "$f"
  if [[ "$LAST_STATUS" -eq 1 ]] && grep -q 'manifestVersion' <<<"$LAST_OUTPUT"; then
    pass "boolean supplied for integer manifestVersion fails (integer-vs-boolean trap)"
  else
    fail "expected boolean-for-integer rejection: exit $LAST_STATUS, output: $LAST_OUTPUT"
  fi
}

case_multiple_violations() {
  local f="$TMPDIR/multi-bad.json"
  valid_manifest | jq 'del(.world) | .personas[0].role = "overlord" | .personas[0].sandboxOnly = false' >"$f"
  run_validate "$WS_SCHEMA" "$f"
  local line_count
  line_count="$(grep -c . <<<"$LAST_OUTPUT" || true)"
  if [[ "$LAST_STATUS" -eq 1 ]] && [[ "$line_count" -ge 3 ]]; then
    pass "multiple simultaneous violations are all reported ($line_count lines)"
  else
    fail "expected >=3 violation lines, got $line_count (exit $LAST_STATUS): $LAST_OUTPUT"
  fi
}

case_valid_sidecar_schema() {
  local f="$TMPDIR/valid-sidecar.json"
  valid_sidecar >"$f"
  run_validate "$SS_SCHEMA" "$f"
  if [[ "$LAST_STATUS" -eq 0 ]]; then
    pass "valid sidecar passes its schema"
  else
    fail "valid sidecar should pass: $LAST_OUTPUT"
  fi
}

case_sidecar_missing_mnemonic() {
  local f="$TMPDIR/sidecar-missing-mnemonic.json"
  valid_sidecar | jq 'del(.identities[0].mnemonic)' >"$f"
  run_validate "$SS_SCHEMA" "$f"
  if [[ "$LAST_STATUS" -eq 1 ]] && grep -q 'mnemonic' <<<"$LAST_OUTPUT"; then
    pass "sidecar identity missing mnemonic fails validation"
  else
    fail "expected missing-mnemonic rejection: exit $LAST_STATUS, output: $LAST_OUTPUT"
  fi
}

case_sidecar_malformed_mnemonic() {
  local f="$TMPDIR/sidecar-malformed-mnemonic.json"
  valid_sidecar | jq '.identities[0].mnemonic = "only three words"' >"$f"
  run_validate "$SS_SCHEMA" "$f"
  if [[ "$LAST_STATUS" -eq 1 ]] && grep -q 'mnemonic' <<<"$LAST_OUTPUT"; then
    pass "sidecar mnemonic with the wrong word count fails the 12-word pattern"
  else
    fail "expected malformed-mnemonic rejection: exit $LAST_STATUS, output: $LAST_OUTPUT"
  fi
}

case_nonexistent_schema() {
  local f="$TMPDIR/valid-manifest-for-404.json"
  valid_manifest >"$f"
  run_validate "$REPO_ROOT/schemas/does-not-exist.schema.json" "$f"
  if [[ "$LAST_STATUS" -eq 2 ]]; then
    pass "nonexistent schema file returns exit 2 (distinguishable from invalid-document exit 1)"
  else
    fail "expected exit 2 for nonexistent schema, got $LAST_STATUS: $LAST_OUTPUT"
  fi
}

case_unsupported_keyword_optional_property() {
  local schema="$TMPDIR/unsupported-keyword-schema.json"
  local instance="$TMPDIR/unsupported-keyword-instance.json"
  cat >"$schema" <<'JSON'
{
  "type": "object",
  "properties": {
    "note": { "type": "string", "format": "date-time" }
  }
}
JSON
  echo '{}' >"$instance"
  run_validate "$schema" "$instance"
  if [[ "$LAST_STATUS" -eq 2 ]] && grep -q 'format' <<<"$LAST_OUTPUT"; then
    pass "unsupported keyword under an optional, instance-omitted property is refused (schema shape check does not depend on which instance keys are present)"
  else
    fail "expected exit 2 for unsupported keyword under an omitted optional property: exit $LAST_STATUS, output: $LAST_OUTPUT"
  fi
}

case_pattern_anchor_rejects_trailing_newline() {
  local schema="$TMPDIR/hex-pattern-schema.json"
  local instance="$TMPDIR/hex-pattern-instance.json"
  cat >"$schema" <<'JSON'
{ "type": "string", "pattern": "^0x[0-9a-f]{4}$" }
JSON
  jq -n '"0xdead\n"' >"$instance"
  run_validate "$schema" "$instance"
  if [[ "$LAST_STATUS" -eq 1 ]]; then
    pass "pattern ending in an unescaped \$ rejects a value with a trailing newline"
  else
    fail "expected exit 1 for trailing-newline bypass of a \$-anchored pattern: exit $LAST_STATUS, output: $LAST_OUTPUT"
  fi
}

case_sidecar_mode_function() {
  local f="$TMPDIR/mode-sidecar.json"
  valid_sidecar >"$f"

  chmod 600 "$f"
  local result600
  # shellcheck source=scripts/check-world-manifest.sh
  if (source "$CHECK_SCRIPT"; check_sidecar_mode "$f") >/dev/null 2>&1; then
    result600=0
  else
    result600=$?
  fi

  chmod 644 "$f"
  local result644
  # shellcheck source=scripts/check-world-manifest.sh
  if (source "$CHECK_SCRIPT"; check_sidecar_mode "$f") >/dev/null 2>&1; then
    result644=0
  else
    result644=$?
  fi

  chmod 600 "$f"

  if [[ "$result600" -eq 0 && "$result644" -ne 0 ]]; then
    pass "check_sidecar_mode accepts 0600 and rejects a looser mode (0644)"
  else
    fail "check_sidecar_mode mode check misbehaved: 0600->$result600 0644->$result644"
  fi
}

# make_fixture_world <name-suffix> — writes a committed-looking recipe under
# worlds/<world>.world.json plus matching manifest/sidecar under
# data/world/<world>/ using a real derived identity (needed for the
# correspondence + recipe-drift layers). Registers paths for cleanup.
# Echoes the world name.
make_fixture_world() {
  local world="world-schema-test-$1-$$"
  local dir="$REPO_ROOT/data/world/$world"
  local recipe_file="$REPO_ROOT/worlds/$world.world.json"
  local identity_json
  mkdir -p "$dir"
  FIXTURE_WORLD_DIRS+=("$dir")
  FIXTURE_WORLD_FILES+=("$recipe_file")

  identity_json="$(python3 "$REPO_ROOT/scripts/derive-identity.py" \
    --root-seed "world-schema-test-seed-$$" \
    --recipe "pacto-dev-world/v1" \
    --label bosun \
    --json)"

  cat >"$recipe_file" <<JSON
{
  "recipe": "pacto-dev-world/v1",
  "devRootSeed": "world-schema-test-seed-$$",
  "world": {
    "name": "$world",
    "relayEndpoint": "wss://localhost:7001",
    "chain": { "endpoint": "http://localhost:8545", "chainId": 31337 }
  },
  "cast": [
    {
      "name": "bosun",
      "role": "steward",
      "botId": "bosun",
      "squadRole": "admin"
    }
  ]
}
JSON

  jq -n --argjson id "$identity_json" --arg world "$world" '{
    manifestVersion: 1,
    recipe: { id: "pacto-dev-world/v1", public: true },
    world: {
      name: $world,
      relayEndpoint: "wss://localhost:7001",
      chain: { endpoint: "http://localhost:8545", chainId: 31337 }
    },
    personas: [{
      name: "bosun",
      role: "steward",
      npub: $id.npub,
      ethAddress: $id.ethAddress,
      botId: "bosun",
      squadRole: "admin",
      derivation: { recipe: "pacto-dev-world/v1", label: "bosun" },
      sandboxOnly: true
    }]
  }' >"$dir/world-state.json"

  jq -n --argjson id "$identity_json" '{
    manifestVersion: 1,
    recipe: "pacto-dev-world/v1",
    identities: [{
      name: "bosun",
      mnemonic: $id.mnemonic,
      npub: $id.npub,
      nsec: $id.nsec,
      ethAddress: $id.ethAddress,
      ethPrivateKey: $id.ethPrivateKey,
      sandboxOnly: true
    }]
  }' >"$dir/world-secrets.json"
  chmod 600 "$dir/world-secrets.json"

  LAST_FIXTURE_WORLD="$world"
}

case_cross_document_valid_passes() {
  local world dir status output
  make_fixture_world valid
  world="$LAST_FIXTURE_WORLD"
  dir="$REPO_ROOT/data/world/$world"

  if output="$(WORLD="$world" "$CHECK_SCRIPT" 2>&1)"; then
    status=0
  else
    status=$?
  fi

  if [[ "$status" -eq 0 ]]; then
    pass "check-world-manifest.sh passes for a matching manifest/sidecar fixture pair"
  else
    fail "expected matching fixture pair to pass check-world-manifest.sh: exit $status, output: $output"
  fi
}

case_cross_document_identity_count() {
  local world dir status output
  make_fixture_world identity-count
  world="$LAST_FIXTURE_WORLD"
  dir="$REPO_ROOT/data/world/$world"
  # Sidecar carries an extra identity absent from the manifest's one persona.
  jq '.identities += [.identities[0] + {name: "captain"}]' \
    "$dir/world-secrets.json" >"$dir/world-secrets.json.tmp"
  mv "$dir/world-secrets.json.tmp" "$dir/world-secrets.json"
  chmod 600 "$dir/world-secrets.json"

  if output="$(WORLD="$world" "$CHECK_SCRIPT" 2>&1)"; then
    status=0
  else
    status=$?
  fi

  if [[ "$status" -ne 0 ]] && grep -qi 'identit' <<<"$output"; then
    pass "sidecar identity count disagreeing with the manifest is caught by the cross-document check"
  else
    fail "expected identity-count mismatch to be caught: exit $status, output: $output"
  fi
}

case_cross_document_value_mismatch() {
  local world dir status output
  make_fixture_world value-mismatch
  world="$LAST_FIXTURE_WORLD"
  dir="$REPO_ROOT/data/world/$world"
  jq --arg addr "0x1111111111111111111111111111111111111111" \
    '.identities[0].ethAddress = $addr' \
    "$dir/world-secrets.json" >"$dir/world-secrets.json.tmp"
  mv "$dir/world-secrets.json.tmp" "$dir/world-secrets.json"
  chmod 600 "$dir/world-secrets.json"

  if output="$(WORLD="$world" "$CHECK_SCRIPT" 2>&1)"; then
    status=0
  else
    status=$?
  fi

  if [[ "$status" -ne 0 ]] && grep -qi 'mismatch' <<<"$output"; then
    pass "sidecar ethAddress disagreeing with the manifest persona's is caught by the cross-document check"
  else
    fail "expected ethAddress mismatch to be caught: exit $status, output: $output"
  fi
}

main() {
  echo "World manifest + secrets sidecar schema test suite"
  echo "===================================================="

  case_valid_manifest
  case_missing_required_field
  case_version_window
  case_sandbox_only_false
  case_sandbox_only_omitted
  case_additional_property
  case_malformed_npub
  case_malformed_eth_address
  case_enum_role
  case_enum_squad_role
  case_empty_personas
  case_boolean_for_integer
  case_multiple_violations
  case_valid_sidecar_schema
  case_sidecar_missing_mnemonic
  case_sidecar_malformed_mnemonic
  case_nonexistent_schema
  case_unsupported_keyword_optional_property
  case_pattern_anchor_rejects_trailing_newline
  case_sidecar_mode_function
  case_cross_document_valid_passes
  case_cross_document_identity_count
  case_cross_document_value_mismatch

  echo
  if [[ "$failed" -eq 0 ]]; then
    echo -e "${GREEN}All world-schema tests passed.${NC}"
    exit 0
  else
    echo -e "${RED}Some world-schema tests failed.${NC}"
    exit 1
  fi
}

main "$@"
