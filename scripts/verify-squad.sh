#!/usr/bin/env bash
set -euo pipefail

# Pacto squad debug report.
#
# Gathers on-chain verification data for a seeded Nave Pirata squad: registry
# cross-check, component bytecode, Safe state, governance parameters, hat
# details, and current members (captain + crew). Useful after `make seed-squad`.
#
# Usage:
#   make verify-squad
# or directly:
#   ./scripts/verify-squad.sh
#
# Environment variables:
#   ANVIL_RPC_URL        Anvil JSON-RPC endpoint (default: http://localhost:8545)
#   PACTO_SQUAD_ARTIFACT Path to squad.json (default: ./data/deployments/31337/squad.json)
#   PACTO_GOV_ARTIFACT   Path to full-system.json (default: ./data/deployments/31337/full-system.json)
#   PACTO_SQUAD_CANDIDATE_ADDRESS  Optional ETH address to check for crew membership

export PATH="$HOME/.foundry/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEPLOYMENTS_DIR="$REPO_ROOT/data/deployments/31337"
SQUAD_ARTIFACT="${PACTO_SQUAD_ARTIFACT:-$DEPLOYMENTS_DIR/squad.json}"
FULL_SYSTEM_ARTIFACT="${PACTO_GOV_ARTIFACT:-$DEPLOYMENTS_DIR/full-system.json}"
RPC_URL="${ANVIL_RPC_URL:-http://localhost:8545}"
CONFIG_FILE="$REPO_ROOT/pacto-bot-api.toml"

TRANSFER_SINGLE_SIG="TransferSingle(address,address,address,uint256,uint256)"
TRANSFER_SINGLE_TOPIC="0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

failed=0
warned=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; failed=1; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; warned=1; }
info() { echo -e "  ${BLUE}ℹ${NC} $1"; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo -e "${RED}[verify-squad]${NC} required command not found: $1" >&2
    exit 1
  fi
}

require_file() {
  if [ ! -f "$1" ]; then
    echo -e "${RED}[verify-squad]${NC} missing file: $1" >&2
    echo "  Run 'make seed-squad' first, or set PACTO_SQUAD_ARTIFACT." >&2
    exit 1
  fi
}

# Generic cast call wrapper. Signature must include the return type, e.g. "balanceOf(address)(uint256)".
cast_call() {
  local addr="$1"
  local sig="$2"
  shift 2
  cast call --rpc-url "$RPC_URL" "$addr" "$sig" "$@"
}

# Read a single uint256-like value and strip the scientific notation suffix.
uint_value() {
  cast_call "$@" | awk '{print $1}'
}

# Strip the optional scientific-notation suffix cast prints after large numbers.
strip_suffix() {
  sed -E 's/[[:space:]]+\[[^]]+\]$//' <<< "$1"
}

# Extract a 40-char address from a 32-byte log topic (0x + 64 hex chars).
topic_to_addr() {
  local topic="$1"
  printf '0x%.40s' "${topic: -40}"
}

# Convert a hex address to lowercase for comparison.
lower() {
  tr '[:upper:]' '[:lower:]' <<< "$1"
}

# Convert a hex string to a decimal string. Falls back to printing the hex if cast fails.
hex_to_dec() {
  cast to-dec "$1" 2>/dev/null || printf '%s' "$1"
}

print_header() {
  echo
  echo "Squad debug report"
  echo "=================="
  echo "  RPC:        $RPC_URL"
  echo "  Squad artifact:    $SQUAD_ARTIFACT"
  echo "  System artifact:   $FULL_SYSTEM_ARTIFACT"
  echo
}

wait_for_rpc() {
  if ! cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    echo -e "${RED}[verify-squad]${NC} Anvil is not responding at $RPC_URL" >&2
    echo "  Start the stack with: make up" >&2
    exit 1
  fi
}

load_artifacts() {
  SQUAD_CHAIN_ID=$(jq -r '.chainId' "$SQUAD_ARTIFACT")
  SAFE=$(jq -r '.safe' "$SQUAD_ARTIFACT")
  QUARTERMASTER=$(jq -r '.quartermaster' "$SQUAD_ARTIFACT")
  MUTINY_MODULE=$(jq -r '.mutinyModule' "$SQUAD_ARTIFACT")
  TREASURY_AUTHORITY=$(jq -r '.treasuryAuthority' "$SQUAD_ARTIFACT")
  SQUAD_ADMIN=$(jq -r '.squadAdminProxy' "$SQUAD_ARTIFACT")
  TOP_HAT_ID=$(jq -r '.topHatId' "$SQUAD_ARTIFACT")

  HATS=$(jq -r '.hats' "$FULL_SYSTEM_ARTIFACT")
  REGISTRY=$(jq -r '.navePirataRegistry' "$FULL_SYSTEM_ARTIFACT")
  FACTORY=$(jq -r '.navePirataFactory' "$FULL_SYSTEM_ARTIFACT")
  DEPLOYER=$(jq -r '.deployer' "$FULL_SYSTEM_ARTIFACT")

  RPC_CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
  BLOCK_NUMBER=$(cast block-number --rpc-url "$RPC_URL")
}

print_artifacts() {
  echo "On-chain context"
  echo "  Chain ID (artifact): $SQUAD_CHAIN_ID"
  echo "  Chain ID (RPC):      $RPC_CHAIN_ID"
  echo "  Block number:        $BLOCK_NUMBER"
  echo
  if [ "$SQUAD_CHAIN_ID" != "$RPC_CHAIN_ID" ]; then
    fail "artifact chain ID ($SQUAD_CHAIN_ID) does not match RPC chain ID ($RPC_CHAIN_ID)"
  else
    pass "artifact chain ID matches RPC chain ID"
  fi
  echo
}

print_squad_identity() {
  echo "Squad identity"
  echo "  Top hat ID:        $TOP_HAT_ID"
  echo "  Safe:              $SAFE"
  echo "  Quartermaster:     $QUARTERMASTER"
  echo "  MutinyModule:      $MUTINY_MODULE"
  echo "  TreasuryAuthority: $TREASURY_AUTHORITY"
  echo "  SquadAdmin:        $SQUAD_ADMIN"
  echo
}

check_registry() {
  echo "Registry cross-check"
  local registry_deployment
  if ! registry_deployment=$(cast_call "$REGISTRY" "deployment(uint256)(address,address,address,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint64,address)" "$TOP_HAT_ID" 2>/dev/null); then
    fail "registry read failed"
    return
  fi

  local reg_addrs
  reg_addrs=$(grep -oE '\b0x[0-9a-fA-F]{40}\b' <<< "$registry_deployment" || true)
  local count
  count=$(wc -w <<< "$reg_addrs" | tr -d ' ')

  if [ "$count" -lt 5 ]; then
    fail "registry returned fewer than 5 addresses (got $count); squad may not be registered"
    return
  fi

  local -a expected=([0]="$SAFE" [1]="$QUARTERMASTER" [2]="$MUTINY_MODULE" [3]="$TREASURY_AUTHORITY" [4]="$SQUAD_ADMIN")
  local -a actual
  mapfile -t actual <<< "$reg_addrs"
  local mismatch=0
  for i in 0 1 2 3 4; do
    if [ "$(lower "${actual[$i]}")" != "$(lower "${expected[$i]}")" ]; then
      mismatch=1
      fail "registry address[ $i ] (${actual[$i]}) does not match artifact (${expected[$i]})"
    fi
  done
  if [ "$mismatch" -eq 0 ]; then
    pass "registry addresses match squad.json"
  fi
  echo
}

check_code() {
  echo "Contract bytecode"
  local name addr size
  for pair in "Safe:$SAFE" "Quartermaster:$QUARTERMASTER" "MutinyModule:$MUTINY_MODULE" "TreasuryAuthority:$TREASURY_AUTHORITY" "SquadAdmin:$SQUAD_ADMIN"; do
    name="${pair%%:*}"
    addr="${pair##*:}"
    size=$(cast codesize --rpc-url "$RPC_URL" "$addr" 2>/dev/null || echo 0)
    if [ "$size" -eq 0 ]; then
      fail "$name ($addr) has no on-chain code"
    else
      pass "$name ($addr) has code ($size bytes)"
    fi
  done
  echo
}

check_safe() {
  echo "Safe state ($SAFE)"
  local owners threshold modules_raw balance
  owners=$(cast_call "$SAFE" "getOwners()(address[])") || owners=""
  threshold=$(cast_call "$SAFE" "getThreshold()(uint256)" 2>/dev/null || echo "?")
  modules_raw=$(cast_call "$SAFE" "getModulesPaginated(address,uint256)(address[],address)" 0x0000000000000000000000000000000000000001 10 2>/dev/null) || modules_raw=""
  balance=$(cast balance --rpc-url "$RPC_URL" "$SAFE" 2>/dev/null || echo "?")

  # getModulesPaginated returns the array on the first line and the next sentinel on the second.
  local -a modules_lines
  mapfile -t modules_lines <<< "$modules_raw"
  local modules="${modules_lines[0]:-}"

  echo "  Owners:    $owners"
  echo "  Threshold: $threshold"
  echo "  Modules:   $modules"
  echo "  Balance:   $balance"

  if [ -n "$owners" ] && grep -q "\b$TREASURY_AUTHORITY\b" <<< "$owners"; then
    pass "TreasuryAuthority is a Safe owner"
  else
    fail "TreasuryAuthority is not a Safe owner"
  fi

  if [ -n "$modules" ] && grep -q "\b$TREASURY_AUTHORITY\b" <<< "$modules"; then
    pass "TreasuryAuthority is an enabled Safe module"
  else
    fail "TreasuryAuthority is not an enabled Safe module"
  fi
  echo
}

check_governance_params() {
  echo "Governance parameters"

  # Quartermaster
  QM_CAPTAIN_HAT_ID=$(uint_value "$QUARTERMASTER" "captainHatId()(uint256)")
  QM_CREW_HAT_ID=$(uint_value "$QUARTERMASTER" "crewHatId()(uint256)")
  QM_MUTINY_ACTIVE=$(uint_value "$QUARTERMASTER" "mutinyActive()(bool)")
  QM_DELAY=$(uint_value "$QUARTERMASTER" "crewChangeDelay()(uint256)")
  echo "  Quartermaster"
  echo "    captainHatId: $QM_CAPTAIN_HAT_ID"
  echo "    crewHatId:    $QM_CREW_HAT_ID"
  echo "    mutinyActive: $QM_MUTINY_ACTIVE"
  echo "    crewChangeDelay: ${QM_DELAY}s"

  # MutinyModule
  MM_CAPTAIN=$(cast_call "$MUTINY_MODULE" "captain()(address)")
  MM_CAPTAIN_HAT_ID=$(uint_value "$MUTINY_MODULE" "captainHatId()(uint256)")
  MM_CREW_HAT_ID=$(uint_value "$MUTINY_MODULE" "crewHatId()(uint256)")
  MM_MUTINY_ROLE_HAT_ID=$(uint_value "$MUTINY_MODULE" "mutinyRoleHatId()(uint256)")
  MM_QM_ROLE_HAT_ID=$(uint_value "$MUTINY_MODULE" "quartermasterRoleHatId()(uint256)")
  MM_ACTIVE_MUTINY=$(uint_value "$MUTINY_MODULE" "activeMutinyId()(uint256)")
  echo "  MutinyModule"
  echo "    captain:      $MM_CAPTAIN"
  echo "    captainHatId: $MM_CAPTAIN_HAT_ID"
  echo "    crewHatId:    $MM_CREW_HAT_ID"
  echo "    mutinyRoleHatId: $MM_MUTINY_ROLE_HAT_ID"
  echo "    quartermasterRoleHatId: $MM_QM_ROLE_HAT_ID"
  echo "    activeMutinyId: $MM_ACTIVE_MUTINY"

  # TreasuryAuthority
  TA_CAPTAIN_HAT_ID=$(uint_value "$TREASURY_AUTHORITY" "captainHatId()(uint256)")
  TA_CREW_HAT_ID=$(uint_value "$TREASURY_AUTHORITY" "crewHatId()(uint256)")
  TA_ROLE_HAT_ID=$(uint_value "$TREASURY_AUTHORITY" "treasuryAuthorityRoleHatId()(uint256)")
  TA_EXPIRY=$(uint_value "$TREASURY_AUTHORITY" "proposalExpiry()(uint256)")
  TA_VOTE_MODE=$(uint_value "$TREASURY_AUTHORITY" "crewVoteMode()(uint8)")
  TA_QUORUM=$(uint_value "$TREASURY_AUTHORITY" "quorumBps()(uint256)")
  TA_SAFE=$(cast_call "$TREASURY_AUTHORITY" "SAFE()(address)")
  echo "  TreasuryAuthority"
  echo "    captainHatId: $TA_CAPTAIN_HAT_ID"
  echo "    crewHatId:    $TA_CREW_HAT_ID"
  echo "    treasuryAuthorityRoleHatId: $TA_ROLE_HAT_ID"
  echo "    proposalExpiry: ${TA_EXPIRY}s"
  echo "    crewVoteMode: $TA_VOTE_MODE (0=MAJORITY_SNAPSHOT, 1=QUORUM_OF_CAST)"
  echo "    quorumBps:    $TA_QUORUM"
  echo "    SAFE:         $TA_SAFE"

  # Cross-check hat IDs across components
  if [ "$QM_CAPTAIN_HAT_ID" = "$MM_CAPTAIN_HAT_ID" ] && [ "$MM_CAPTAIN_HAT_ID" = "$TA_CAPTAIN_HAT_ID" ]; then
    pass "captainHatId is consistent across components"
  else
    fail "captainHatId mismatch: QM=$QM_CAPTAIN_HAT_ID MM=$MM_CAPTAIN_HAT_ID TA=$TA_CAPTAIN_HAT_ID"
  fi
  if [ "$QM_CREW_HAT_ID" = "$MM_CREW_HAT_ID" ] && [ "$MM_CREW_HAT_ID" = "$TA_CREW_HAT_ID" ]; then
    pass "crewHatId is consistent across components"
  else
    fail "crewHatId mismatch: QM=$QM_CREW_HAT_ID MM=$MM_CREW_HAT_ID TA=$TA_CREW_HAT_ID"
  fi
  if [ "$(lower "$TA_SAFE")" = "$(lower "$SAFE")" ]; then
    pass "TreasuryAuthority SAFE matches squad Safe"
  else
    fail "TreasuryAuthority SAFE ($TA_SAFE) does not match squad Safe ($SAFE)"
  fi
  echo
}

view_hat_line() {
  local hat_id="$1"
  local label="$2"
  local result
  if ! result=$(cast_call "$HATS" "viewHat(uint256)(string,uint32,uint32,address,address,string,uint16,bool,bool)" "$hat_id" 2>/dev/null); then
    warn "$label ($hat_id): viewHat failed"
    return
  fi
  local -a lines
  mapfile -t lines <<< "$result"
  local details="${lines[0]:-}"
  local max_supply="$(strip_suffix "${lines[1]:-}")"
  local supply="$(strip_suffix "${lines[2]:-}")"
  local eligibility="${lines[3]:-}"
  local toggle="${lines[4]:-}"
  local active="${lines[8]:-}"
  echo "  $label ($hat_id)"
  echo "    details:    $details"
  echo "    supply:     $supply / $max_supply"
  echo "    eligibility:$eligibility"
  echo "    toggle:     $toggle"
  echo "    active:     $active"
}

is_wearer() {
  local addr="$1"
  local hat_id="$2"
  cast_call "$HATS" "isWearerOfHat(address,uint256)(bool)" "$addr" "$hat_id" 2>/dev/null | grep -q "true"
}

balance_of() {
  local addr="$1"
  local hat_id="$2"
  uint_value "$HATS" "balanceOf(address,uint256)(uint256)" "$addr" "$hat_id"
}

check_hats_and_members() {
  echo "Hats and members"

  # Squad-admin hat ID
  SA_HAT_ID=$(uint_value "$SQUAD_ADMIN" "squadAdminHatId()(uint256)")
  SA_CAPTAIN_HAT_ID=$(uint_value "$SQUAD_ADMIN" "captainHatId()(uint256)")

  view_hat_line "$TOP_HAT_ID" "Top hat"
  view_hat_line "$QM_CAPTAIN_HAT_ID" "Captain hat"
  view_hat_line "$QM_CREW_HAT_ID" "Crew hat"
  view_hat_line "$SA_HAT_ID" "Squad-admin hat"
  view_hat_line "$MM_MUTINY_ROLE_HAT_ID" "MutinyRole hat"
  view_hat_line "$MM_QM_ROLE_HAT_ID" "QuartermasterRole hat"
  view_hat_line "$TA_ROLE_HAT_ID" "TreasuryAuthorityRole hat"
  echo

  # Captain
  echo "  Captain"
  echo "    MutinyModule.captain(): $MM_CAPTAIN"
  if is_wearer "$MM_CAPTAIN" "$QM_CAPTAIN_HAT_ID"; then
    pass "captain address wears the captain hat"
  else
    fail "captain address does not wear the captain hat"
  fi

  # Safe / top hat
  if is_wearer "$SAFE" "$TOP_HAT_ID"; then
    pass "Safe wears the top hat"
  else
    fail "Safe does not wear the top hat"
  fi

  # Role hat wearers
  if is_wearer "$MUTINY_MODULE" "$MM_MUTINY_ROLE_HAT_ID"; then
    pass "MutinyModule wears the MutinyRole hat"
  else
    fail "MutinyModule does not wear the MutinyRole hat"
  fi
  if is_wearer "$QUARTERMASTER" "$MM_QM_ROLE_HAT_ID"; then
    pass "Quartermaster wears the QuartermasterRole hat"
  else
    fail "Quartermaster does not wear the QuartermasterRole hat"
  fi
  if is_wearer "$TREASURY_AUTHORITY" "$TA_ROLE_HAT_ID"; then
    pass "TreasuryAuthority wears the TreasuryAuthorityRole hat"
  else
    fail "TreasuryAuthority does not wear the TreasuryAuthorityRole hat"
  fi
  if is_wearer "$SQUAD_ADMIN" "$SA_HAT_ID"; then
    pass "SquadAdmin wears the squad-admin hat"
  else
    fail "SquadAdmin does not wear the squad-admin hat"
  fi

  # Crew
  echo
  echo "  Crew"
  local crew_supply
  crew_supply=$(uint_value "$HATS" "hatSupply(uint256)(uint32)" "$QM_CREW_HAT_ID")
  echo "    Crew hat supply: $crew_supply"

  if [ "$crew_supply" -eq 0 ]; then
    info "no crew members yet (crew hat supply is 0)"
  else
    enumerate_crew "$QM_CREW_HAT_ID"
  fi

  # Optional candidate address
  if [ -n "${PACTO_SQUAD_CANDIDATE_ADDRESS:-}" ]; then
    echo
    echo "  Candidate check (PACTO_SQUAD_CANDIDATE_ADDRESS)"
    echo "    Address: $PACTO_SQUAD_CANDIDATE_ADDRESS"
    local bal
    bal=$(balance_of "$PACTO_SQUAD_CANDIDATE_ADDRESS" "$QM_CREW_HAT_ID")
    echo "    Crew hat balance: $bal"
    if [ "$bal" -gt 0 ]; then
      pass "candidate wears the crew hat"
    else
      warn "candidate does not wear the crew hat yet"
    fi
  fi

  # Artifact crew members (seeded by seed-squad.sh)
  if [ -f "$SQUAD_ARTIFACT" ] && jq -e '.crewMembers' "$SQUAD_ARTIFACT" >/dev/null 2>&1; then
    echo
    echo "  Seeded crew members (from squad.json)"
    local label addr
    while IFS= read -r label; do
      addr="${label##* }"
      echo "    $label"
      if is_wearer "$addr" "$QM_CREW_HAT_ID"; then
        pass "$(echo "$label" | cut -d: -f1) wears the crew hat"
      else
        fail "$(echo "$label" | cut -d: -f1) does not wear the crew hat"
      fi
    done < <(jq -r '.crewMembers[] | "\(.bot_id // "explicit"): \(.address)"' "$SQUAD_ARTIFACT")
  fi

  echo
}

enumerate_crew() {
  local crew_hat_id="$1"
  local logs_json tmp
  tmp=$(mktemp)

  if ! logs_json=$(cast logs "$TRANSFER_SINGLE_TOPIC" \
    --from-block 0 \
    --to-block latest \
    --address "$HATS" \
    --rpc-url "$RPC_URL" \
    --json 2>/dev/null); then
    warn "could not query Hats TransferSingle logs for crew enumeration"
    rm -f "$tmp"
    return
  fi

  if ! jq -e '. | length > 0' >/dev/null 2>&1 <<< "$logs_json"; then
    info "no TransferSingle events found for crew enumeration"
    rm -f "$tmp"
    return
  fi

  jq -r '.[] | "\(.topics[2]) \(.topics[3]) \(.data)"' <<< "$logs_json" > "$tmp"

  declare -A balances
  local from to data id_hex id_dec
  while read -r from to data; do
    id_hex="0x${data:2:64}"
    id_dec=$(hex_to_dec "$id_hex")
    if [ "$id_dec" != "$crew_hat_id" ]; then
      continue
    fi
    from=$(topic_to_addr "$from")
    to=$(topic_to_addr "$to")
    if [ "$from" != "0x0000000000000000000000000000000000000000" ]; then
      balances["$from"]=$((${balances["$from"]:-0} - 1))
    fi
    balances["$to"]=$((${balances["$to"]:-0} + 1))
  done < "$tmp"
  rm -f "$tmp"

  local found=0
  for addr in "${!balances[@]}"; do
    if [ "${balances[$addr]}" -gt 0 ]; then
      found=1
      echo "    Crew member: $addr (balance: ${balances[$addr]})"
    fi
  done
  if [ "$found" -eq 0 ]; then
    info "no crew members derived from TransferSingle events"
  fi
}

print_known_identities() {
  if [ ! -f "$CONFIG_FILE" ]; then
    return
  fi

  echo "Known identities from $CONFIG_FILE"
  local captain_npub candidate_npub
  captain_npub=$(grep -A3 '^\[\[bots\]\]' "$CONFIG_FILE" | grep -A3 'id = "captain"' | grep 'npub' | head -n1 | grep -oE 'npub1[0-9a-z]+' || true)
  candidate_npub=$(grep -A3 '^\[\[bots\]\]' "$CONFIG_FILE" | grep -A3 'id = "candidate"' | grep 'npub' | head -n1 | grep -oE 'npub1[0-9a-z]+' || true)

  if [ -n "$captain_npub" ]; then
    echo "  captain bot npub:  $captain_npub"
  fi
  if [ -n "$candidate_npub" ]; then
    echo "  candidate bot npub: $candidate_npub"
  fi
  echo
}

print_summary() {
  echo "Summary"
  if [ "$failed" -eq 0 ] && [ "$warned" -eq 0 ]; then
    pass "all checks passed"
  elif [ "$failed" -eq 0 ]; then
    warn "all critical checks passed, but warnings were reported"
  else
    fail "one or more critical checks failed"
  fi
  echo
}

main() {
  require_cmd cast
  require_cmd jq
  require_file "$SQUAD_ARTIFACT"
  require_file "$FULL_SYSTEM_ARTIFACT"

  wait_for_rpc
  load_artifacts
  print_header
  print_squad_identity
  print_artifacts
  check_registry
  check_code
  check_safe
  check_governance_params
  check_hats_and_members
  print_known_identities
  print_summary

  if [ "$failed" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
