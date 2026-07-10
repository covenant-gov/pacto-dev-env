#!/usr/bin/env bash
set -euo pipefail

# Seed a Nave Pirata squad on the local Anvil testnet.
#
# Usage:
#   ./scripts/seed-squad.sh
#
# Required environment variables (or auto-create; see below):
#   PACTO_SQUAD_CAPTAIN_NPUB  - captain Nostr public key (hex or bech32 npub)
#   PACTO_SQUAD_CANDIDATE_NPUB - candidate Nostr public key (hex or bech32 npub)
#
# Optional environment variables:
#   PACTO_GOV_DIR        - path to pacto-gov repo (default: ../pacto-gov)
#   ANVIL_RPC_URL        - Anvil RPC endpoint (default: http://localhost:8545)
#   ANVIL_PRIVATE_KEY    - deployer private key
#                          (default: Anvil account #0)
#   PACTO_SQUAD_METADATA_URI - metadata URI for the squad (default: ipfs://Qmdummy)
#   PACTO_SQUAD_CREW_COUNT - number of crew bot identities to create and bootstrap
#                          on-chain (default: 3; set to 0 to skip crew bootstrap)
#   PACTO_SQUAD_CREW_BOT_IDS - comma-separated bot ids to use as crew members
#                          (overrides PACTO_SQUAD_CREW_COUNT when set)
#   PACTO_SQUAD_CREW_ADDRESSES - comma-separated ETH addresses to use as crew
#                          (overrides bot identity creation when set)
#   FORCE_SEED_SQUAD     - set to 1 to re-deploy when squad.json already exists
#   PACTO_AUTO_CREATE_SQUAD_IDENTITIES - set to 1 to skip the prompt and create
#                          the captain/candidate identities automatically
#   PACTO_SQUAD_CAPTAIN_BOT_ID - bot id to use/create in pacto-bot-api.toml (default: captain)
#   PACTO_SQUAD_CANDIDATE_BOT_ID - bot id to use/create in pacto-bot-api.toml (default: candidate)
#
# Identity resolution:
#   1. If the required env vars are set, they are used.
#   2. Otherwise, the script looks for existing `captain` / `candidate` identities
#      in pacto-bot-api.toml and reuses them.
#   3. Otherwise, it prompts to create the identities automatically inside the
#      pacto-bot-api container (or auto-creates if
#      PACTO_AUTO_CREATE_SQUAD_IDENTITIES=1). The resulting identities are
#      appended to pacto-bot-api.toml and the daemon is restarted when running.
#   4. If all of the above fail, it prints explicit `pacto-bot-admin new`
#      instructions and exits with status 1.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PACTO_GOV_DIR="${PACTO_GOV_DIR:-$REPO_ROOT/../pacto-gov}"
if [ ! -d "$PACTO_GOV_DIR" ]; then
  err "PACTO_GOV_DIR does not exist: $PACTO_GOV_DIR"
  exit 1
fi
PACTO_GOV_DIR="$(cd "$PACTO_GOV_DIR" && pwd)"
ANVIL_RPC_URL="${ANVIL_RPC_URL:-http://localhost:8545}"
ANVIL_PRIVATE_KEY="${ANVIL_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
SQUAD_METADATA_URI="${PACTO_SQUAD_METADATA_URI:-ipfs://Qmdummy}"
FORCE_SEED_SQUAD="${FORCE_SEED_SQUAD:-0}"

DEPLOYMENTS_DIR="$REPO_ROOT/data/deployments/31337"
SQUAD_ARTIFACT="$DEPLOYMENTS_DIR/squad.json"
FULL_SYSTEM_ARTIFACT="$DEPLOYMENTS_DIR/full-system.json"

CONFIG_FILE="$REPO_ROOT/pacto-bot-api.toml"
CAPTAIN_BOT_ID="${PACTO_SQUAD_CAPTAIN_BOT_ID:-captain}"
CANDIDATE_BOT_ID="${PACTO_SQUAD_CANDIDATE_BOT_ID:-candidate}"

# If the user already exported the public keys, keep them. Otherwise we will try
# to read them from the daemon config or create them on demand.
PACTO_SQUAD_CAPTAIN_NPUB="${PACTO_SQUAD_CAPTAIN_NPUB:-}"
PACTO_SQUAD_CANDIDATE_NPUB="${PACTO_SQUAD_CANDIDATE_NPUB:-}"

# Crew onboarding: number of crew bot identities, optional explicit bot ids,
# and optional explicit ETH addresses. When PACTO_SQUAD_CREW_ADDRESSES is empty,
# the script creates crew bot identities with pacto-bot-admin and derives their
# Ethereum addresses from their nsec values.
PACTO_SQUAD_CREW_COUNT="${PACTO_SQUAD_CREW_COUNT:-3}"
PACTO_SQUAD_CREW_BOT_IDS="${PACTO_SQUAD_CREW_BOT_IDS:-}"
PACTO_SQUAD_CREW_ADDRESSES="${PACTO_SQUAD_CREW_ADDRESSES:-}"

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

err() { echo -e "${RED}[seed-squad]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[seed-squad]${NC} $*"; }

# Returns 0 if the NavePirataFactory at the recorded address is alive and
# wired to the expected registry, non-zero otherwise.
_factory_is_live() {
  local factory_addr="$1"
  local expected_registry="$2"

  if [ -z "$factory_addr" ] || [ "$factory_addr" = "null" ] || [ "$factory_addr" = "0x0000000000000000000000000000000000000000" ]; then
    return 1
  fi

  if [ -z "$expected_registry" ] || [ "$expected_registry" = "null" ] || [ "$expected_registry" = "0x0000000000000000000000000000000000000000" ]; then
    return 1
  fi

  local registry_addr
  registry_addr="$(cast call "$factory_addr" "REGISTRY()" --rpc-url "$ANVIL_RPC_URL" 2>/dev/null | tr -d '\n')" || return 1
  # cast returns the ABI-encoded address (0x-padded to 32 bytes); extract the actual address.
  registry_addr="0x${registry_addr: -40}"

  if [ "$(echo "$registry_addr" | tr '[:upper:]' '[:lower:]')" != "$(echo "$expected_registry" | tr '[:upper:]' '[:lower:]')" ]; then
    return 1
  fi

  return 0
}

require_env() {
  local name="$1"
  local value="${!name:-}"
  if [ -z "$value" ]; then
    err "Missing required environment variable: $name"
    return 1
  fi
}

print_instructions() {
  {
    echo -e ""
    echo -e "${YELLOW}Squad creation requires two Nostr identities:${NC}"
    echo -e "  - PACTO_SQUAD_CAPTAIN_NPUB  (the squad captain)"
    echo -e "  - PACTO_SQUAD_CANDIDATE_NPUB (a candidate crew member)"
    echo -e ""
    echo -e "Create them with pacto-bot-admin and re-run this script:"
    echo -e ""
    echo -e "  pacto-bot-admin new captain --backend nsec --relays ws://localhost:7000"
    echo -e "  pacto-bot-admin new candidate --backend nsec --relays ws://localhost:7000"
    echo -e ""
    echo -e "Then export the public keys (hex or npub) and run again:"
    echo -e ""
    echo -e "  export PACTO_SQUAD_CAPTAIN_NPUB=<captain-npub>"
    echo -e "  export PACTO_SQUAD_CANDIDATE_NPUB=<candidate-npub>"
    echo -e "  make seed-squad"
    echo -e ""
    echo -e "Alternatively, set PACTO_AUTO_CREATE_SQUAD_IDENTITIES=1 to skip the prompt."
    echo -e ""
  } >&2
}

bot_exists_in_config() {
  local bot_id="$1"
  [ -f "$CONFIG_FILE" ] && grep -q "^id = \"$bot_id\"$" "$CONFIG_FILE"
}

get_npub_from_config() {
  local bot_id="$1"
  "$SCRIPT_DIR/get-bot-secret.py" "$CONFIG_FILE" "$bot_id" npub 2>/dev/null
}

get_nsec_from_config() {
  local bot_id="$1"
  "$SCRIPT_DIR/get-bot-secret.py" "$CONFIG_FILE" "$bot_id" nsec 2>/dev/null
}

ensure_config_exists() {
  if [ -d "$CONFIG_FILE" ]; then
    warn "Removing bogus directory $CONFIG_FILE created by an empty Docker mount..."
    rm -rf "$CONFIG_FILE"
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<EOF
[daemon]
data_dir = "/var/lib/pacto-bot-api"
socket_path = "/var/lib/pacto-bot-api/pacto-bot-api.sock"

EOF
    chmod 600 "$CONFIG_FILE"
  fi
}

copy_artifact_with_docker() {
  local src="$1"
  local dst="$2"
  local dst_dir
  dst_dir="$(dirname "$dst")"
  # If the host can write directly, prefer a plain cp to avoid container churn.
  if cp "$src" "$dst" 2>/dev/null; then
    return 0
  fi
  echo "[seed-squad] Host copy failed; copying through the pacto-anvil container as root..."
  docker run --rm \
    -v "$src:/src:ro" \
    -v "$dst_dir:/dst" \
    --entrypoint cp \
    pacto-anvil:local \
    /src "/dst/$(basename "$dst")"
}

docker_compose() {
  docker compose -f "$REPO_ROOT/docker-compose.yml" "$@"
}

create_identity_in_container() {
  local bot_id="$1"
  local snippet
  echo "Creating bot identity '$bot_id' inside the pacto-bot-api container..."
  snippet="$(docker_compose run --rm --no-deps -T pacto-bot-api \
    pacto-bot-admin new "$bot_id" \
    --backend nsec \
    --relays ws://nostr-relay:8080 \
    --emit-secrets \
    --output /tmp/pacto-bot-admin-identity.toml)"
  if [ -z "$snippet" ]; then
    err "Failed to create bot identity '$bot_id' inside the container."
    exit 1
  fi
  printf '\n%s\n' "$snippet" >> "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  echo "$snippet" | sed -n 's/^npub = "\(.*\)"$/\1/p'
}

restart_pacto_bot_api() {
  local running
  running="$(docker_compose ps pacto-bot-api --status running --format json 2>/dev/null | jq -s 'length' 2>/dev/null || echo 0)"
  if [ "$running" -gt 0 ]; then
    echo "Restarting pacto-bot-api so the new identities are loaded..."
    docker_compose restart pacto-bot-api >/dev/null
  else
    echo "pacto-bot-api is not running; new identities will be picked up on the next start."
  fi
}

prompt_auto_create() {
  if [ "${PACTO_AUTO_CREATE_SQUAD_IDENTITIES:-}" = "1" ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    return 1
  fi
  local answer
  read -r -p "Create required squad identities ('$CAPTAIN_BOT_ID' and '$CANDIDATE_BOT_ID') automatically inside the pacto-bot-api container? [y/N] " answer
  case "$answer" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_squad_identities() {
  if [ -z "$PACTO_SQUAD_CAPTAIN_NPUB" ]; then
    PACTO_SQUAD_CAPTAIN_NPUB="$(get_npub_from_config "$CAPTAIN_BOT_ID")"
    if [ -n "$PACTO_SQUAD_CAPTAIN_NPUB" ]; then
      echo "Reusing existing captain identity from $CONFIG_FILE: $PACTO_SQUAD_CAPTAIN_NPUB"
    fi
  fi
  if [ -z "$PACTO_SQUAD_CANDIDATE_NPUB" ]; then
    PACTO_SQUAD_CANDIDATE_NPUB="$(get_npub_from_config "$CANDIDATE_BOT_ID")"
    if [ -n "$PACTO_SQUAD_CANDIDATE_NPUB" ]; then
      echo "Reusing existing candidate identity from $CONFIG_FILE: $PACTO_SQUAD_CANDIDATE_NPUB"
    fi
  fi

  if [ -n "$PACTO_SQUAD_CAPTAIN_NPUB" ] && [ -n "$PACTO_SQUAD_CANDIDATE_NPUB" ]; then
    return 0
  fi

  if prompt_auto_create; then
    ensure_config_exists
    for bot_id in "$CAPTAIN_BOT_ID" "$CANDIDATE_BOT_ID"; do
      local npub
      if bot_exists_in_config "$bot_id"; then
        echo "Bot identity '$bot_id' already exists in $CONFIG_FILE; reusing it."
        npub="$(get_npub_from_config "$bot_id")"
      else
        npub="$(create_identity_in_container "$bot_id")"
      fi
      if [ "$bot_id" = "$CAPTAIN_BOT_ID" ]; then
        PACTO_SQUAD_CAPTAIN_NPUB="$npub"
      else
        PACTO_SQUAD_CANDIDATE_NPUB="$npub"
      fi
      if [ -z "$npub" ]; then
        err "Could not resolve npub for bot identity '$bot_id'."
        exit 1
      fi
    done
    restart_pacto_bot_api
  else
    print_instructions
    exit 1
  fi

  export PACTO_SQUAD_CAPTAIN_NPUB PACTO_SQUAD_CANDIDATE_NPUB
}

# Derive an Ethereum address from a Nostr nsec using the local helper.
# This matches the covenant-gov/nostr-k-derivs derivation: the Nostr private
# key is used directly as the Ethereum private key.
derive_address_from_nsec() {
  local nsec="$1"
  "$SCRIPT_DIR/derive-eth-address.py" "$nsec"
}

# Build a JSON array of crew member objects from explicit addresses.
build_explicit_crew_json() {
  local addresses=("$@")
  local items=""
  for addr in "${addresses[@]}"; do
    if [ -n "$items" ]; then items="$items,"; fi
    items="$items{\"address\":\"$addr\"}"
  done
  echo "[$items]"
}

# Resolve the list of crew members.
#
# Priority:
#   1. PACTO_SQUAD_CREW_ADDRESSES - use these explicit ETH addresses, no bots.
#   2. PACTO_SQUAD_CREW_BOT_IDS   - use these bot ids (create if missing).
#   3. PACTO_SQUAD_CREW_COUNT     - create crew-1 .. crew-N bot ids.
#
# Populates CREW_MEMBERS_JSON with objects [{bot_id, npub, nsec, address}, ...]
# or [{address}, ...] when explicit addresses are provided.
resolve_crew_members() {
  CREW_MEMBERS_JSON="[]"

  if [ -n "${PACTO_SQUAD_CREW_ADDRESSES:-}" ]; then
    local IFS=','
    local raw
    read -r -a raw <<< "$PACTO_SQUAD_CREW_ADDRESSES"
    local addresses=()
    for entry in "${raw[@]}"; do
      entry="$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      if [ -n "$entry" ]; then
        addresses+=("$entry")
      fi
    done
    CREW_MEMBERS_JSON="$(build_explicit_crew_json "${addresses[@]}")"
    return
  fi

  local bot_ids=()
  if [ -n "${PACTO_SQUAD_CREW_BOT_IDS:-}" ]; then
    local IFS=','
    local raw
    read -r -a raw <<< "$PACTO_SQUAD_CREW_BOT_IDS"
    for entry in "${raw[@]}"; do
      entry="$(printf '%s' "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      if [ -n "$entry" ]; then
        bot_ids+=("$entry")
      fi
    done
  else
    local count
    count="${PACTO_SQUAD_CREW_COUNT:-0}"
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
      err "PACTO_SQUAD_CREW_COUNT must be a non-negative integer (got: $count)"
      exit 1
    fi
    if [ "$count" -gt 100 ]; then
      err "PACTO_SQUAD_CREW_COUNT is too large (>100)"
      exit 1
    fi
    local i
    for i in $(seq 1 "$count"); do
      bot_ids+=("crew-$i")
    done
  fi

  if [ "${#bot_ids[@]}" -eq 0 ]; then
    return
  fi

  ensure_config_exists
  local changed=0
  for bot_id in "${bot_ids[@]}"; do
    if bot_exists_in_config "$bot_id"; then
      echo "Reusing existing crew identity '$bot_id' from $CONFIG_FILE."
    else
      create_identity_in_container "$bot_id"
      changed=1
    fi
  done
  if [ "$changed" -eq 1 ]; then
    restart_pacto_bot_api
  fi

  CREW_MEMBERS_JSON="[]"
  for bot_id in "${bot_ids[@]}"; do
    local npub nsec address
    npub="$(get_npub_from_config "$bot_id")"
    nsec="$(get_nsec_from_config "$bot_id")"
    if [ -z "$nsec" ]; then
      err "Could not read nsec for crew identity '$bot_id' from $CONFIG_FILE"
      exit 1
    fi
    address="$(derive_address_from_nsec "$nsec")"
    CREW_MEMBERS_JSON="$(jq \
      --arg id "$bot_id" \
      --arg npub "$npub" \
      --arg nsec "$nsec" \
      --arg addr "$address" \
      '. + [{bot_id: $id, npub: $npub, nsec: $nsec, address: $addr}]' \
      <<< "$CREW_MEMBERS_JSON")"
  done
}

# Bootstrap the initial crew members via Quartermaster.bootstrapCrew.
# This only works while the crew hat has zero wearers, so it is a one-shot
# seeding helper. Caller must ensure CREW_MEMBERS_JSON is populated.
bootstrap_crew() {
  local quartermaster="$1"
  local count
  count="$(jq 'length' <<< "$CREW_MEMBERS_JSON")"

  if [ "$count" -eq 0 ]; then
    echo "No crew members configured; skipping on-chain crew bootstrap."
    return
  fi

  echo "Bootstrapping $count crew member(s) on Quartermaster $quartermaster..."
  local addr_list
  addr_list="$(jq -r '[.[].address] | join(",")' <<< "$CREW_MEMBERS_JSON")"
  local array_arg="[${addr_list}]"

  cast send "$quartermaster" "bootstrapCrew(address[])" "$array_arg" \
    --private-key "$ANVIL_PRIVATE_KEY" \
    --rpc-url "$ANVIL_RPC_URL" \
    --confirmations 1
}

# Append the crew member list to the squad artifact as a post-deployment
# convenience field. The Solidity script does not write this field. Secrets
# (nsec) are stripped before writing.
append_crew_to_artifact() {
  local artifact="$1"
  local tmp
  tmp=$(mktemp)
  local public_members
  public_members="$(jq '[.[] | {bot_id, npub, address} | with_entries(select(.value != null))]' <<< "$CREW_MEMBERS_JSON")"
  jq --argjson crew "$public_members" \
    '. + {crewMembers: $crew}' "$artifact" > "$tmp"

  if mv "$tmp" "$artifact" 2>/dev/null; then
    return 0
  fi

  # The artifact may be owned by the container user; copy through the anvil
  # image so the destination permissions do not block the update.
  echo "[seed-squad] Host mv failed; updating artifact through the pacto-anvil container as root..."
  local dst_dir
  dst_dir="$(dirname "$artifact")"
  docker run --rm \
    -v "$tmp:/src/crew-squad.json:ro" \
    -v "$dst_dir:/dst" \
    --entrypoint cp \
    pacto-anvil:local \
    /src/crew-squad.json "/dst/$(basename "$artifact")"
  rm -f "$tmp"
}

# Validate that the sibling repo looks right.
if [ ! -f "$PACTO_GOV_DIR/script/DeployNavePirata.s.sol" ]; then
  err "$PACTO_GOV_DIR does not look like the pacto-gov repository (missing script/DeployNavePirata.s.sol)"
  exit 1
fi

# Validate that the full-system deployment exists (infra + master copies).
if [ ! -f "$FULL_SYSTEM_ARTIFACT" ]; then
  err "Missing full-system deployment artifact: $FULL_SYSTEM_ARTIFACT"
  err "Run 'make seed' first to deploy the Pacto governance system."
  exit 1
fi

# Resolve required squad identities (env vars, existing config, or auto-create on demand).
ensure_squad_identities

# Final guard after resolution.
if ! require_env PACTO_SQUAD_CAPTAIN_NPUB || ! require_env PACTO_SQUAD_CANDIDATE_NPUB; then
  print_instructions
  exit 1
fi

mkdir -p "$DEPLOYMENTS_DIR"

if [ "$FORCE_SEED_SQUAD" != "1" ] && [ -f "$SQUAD_ARTIFACT" ]; then
  echo "Squad artifact already exists: $SQUAD_ARTIFACT"
  echo "Run with FORCE_SEED_SQUAD=1 to re-deploy, or run 'make reset' to clear state."
  exit 0
fi

# For a dev squad we use the deployer address itself as the captain.
# The PACTO_SQUAD_*_NPUB env vars are required to enforce identity-aware
# setup and can be consumed by a future env generator in pacto-governance-bots.
CAPTAIN_ADDRESS="$(cast wallet address --private-key "$ANVIL_PRIVATE_KEY")"

NAVE_PIRATA_FACTORY="$(jq -r '.navePirataFactory' "$FULL_SYSTEM_ARTIFACT")"
if [ -z "$NAVE_PIRATA_FACTORY" ] || [ "$NAVE_PIRATA_FACTORY" = "null" ]; then
  err "navePirataFactory address not found in $FULL_SYSTEM_ARTIFACT"
  exit 1
fi

NAVE_PIRATA_REGISTRY="$(jq -r '.navePirataRegistry' "$FULL_SYSTEM_ARTIFACT")"
if ! _factory_is_live "$NAVE_PIRATA_FACTORY" "$NAVE_PIRATA_REGISTRY"; then
  err "NavePirataFactory at $NAVE_PIRATA_FACTORY is not deployed on Anvil (chain may have been reset)."
  err "Run 'make seed' or 'FORCE_SEED=1 make seed' to redeploy the Pacto infrastructure, then retry 'make seed-squad'."
  exit 1
fi

# Read the deployed master copy addresses from the full-system artifact so the
# squad script can use the locally deployed implementations on Anvil.
MASTER_COPY_QUARTERMASTER="$(jq -r '.masterQuartermaster' "$FULL_SYSTEM_ARTIFACT")"
MASTER_COPY_MUTINY_MODULE="$(jq -r '.masterMutinyModule' "$FULL_SYSTEM_ARTIFACT")"
MASTER_COPY_TREASURY_AUTHORITY="$(jq -r '.masterTreasuryAuthority' "$FULL_SYSTEM_ARTIFACT")"
MASTER_COPY_SQUAD_ADMIN_IMPL="$(jq -r '.masterSquadAdminImpl' "$FULL_SYSTEM_ARTIFACT")"
if [ -z "$MASTER_COPY_QUARTERMASTER" ] || [ "$MASTER_COPY_QUARTERMASTER" = "null" ] || \
   [ -z "$MASTER_COPY_MUTINY_MODULE" ] || [ "$MASTER_COPY_MUTINY_MODULE" = "null" ] || \
   [ -z "$MASTER_COPY_TREASURY_AUTHORITY" ] || [ "$MASTER_COPY_TREASURY_AUTHORITY" = "null" ] || \
   [ -z "$MASTER_COPY_SQUAD_ADMIN_IMPL" ] || [ "$MASTER_COPY_SQUAD_ADMIN_IMPL" = "null" ]; then
  err "Missing master copy addresses in $FULL_SYSTEM_ARTIFACT"
  err "Run 'make seed' first to deploy the Pacto governance master copies."
  exit 1
fi

# Compute a fresh saltNonce so repeated runs (or a failed prior run that already
# wrote a squad-<salt>.json) avoid deterministic Safe proxy collisions.
SQUAD_SALT_NONCE=1
for f in "$PACTO_GOV_DIR/deployments/31337"/squad-*.json; do
  if [ -f "$f" ]; then
    salt="$(basename "$f" | sed -n 's/^squad-\([0-9]*\)\.json$/\1/p')"
    if [ -n "$salt" ] && [ "$salt" -ge "$SQUAD_SALT_NONCE" ] 2>/dev/null; then
      SQUAD_SALT_NONCE=$((salt + 1))
    fi
  fi
done

echo "Using saltNonce=$SQUAD_SALT_NONCE for squad deployment."

echo "Waiting for Anvil at $ANVIL_RPC_URL..."
for _ in $(seq 1 30); do
  if cast block-number --rpc-url "$ANVIL_RPC_URL" >/dev/null 2>&1; then
    echo "Anvil is ready."
    break
  fi
  sleep 1
done

cast block-number --rpc-url "$ANVIL_RPC_URL" >/dev/null

# Ensure the canonical Hats / Safe singletons are present on Anvil before the
# squad deploy runs, in case the chain was reset or seeded without them.
"$SCRIPT_DIR/ensure-external-contracts.sh"

echo "Deploying Nave Pirata squad to Anvil (chain ID 31337)..."
echo "  captain:  $CAPTAIN_ADDRESS"
echo "  factory:  $NAVE_PIRATA_FACTORY"
echo "  metadata: $SQUAD_METADATA_URI"

(
  cd "$PACTO_GOV_DIR"
  NAVE_PIRATA_FACTORY="$NAVE_PIRATA_FACTORY" \
    CAPTAIN="$CAPTAIN_ADDRESS" \
    SQUAD_METADATA_URI="$SQUAD_METADATA_URI" \
    MASTER_COPY_QUARTERMASTER="$MASTER_COPY_QUARTERMASTER" \
    MASTER_COPY_MUTINY_MODULE="$MASTER_COPY_MUTINY_MODULE" \
    MASTER_COPY_TREASURY_AUTHORITY="$MASTER_COPY_TREASURY_AUTHORITY" \
    MASTER_COPY_SQUAD_ADMIN_IMPL="$MASTER_COPY_SQUAD_ADMIN_IMPL" \
    SQUAD_SALT_NONCE="$SQUAD_SALT_NONCE" \
    forge script script/DeployNavePirata.s.sol \
      --rpc-url "$ANVIL_RPC_URL" \
      --broadcast \
      --private-key "$ANVIL_PRIVATE_KEY" \
      -vvvv
)

# The forge script writes squad-<saltNonce>.json. Find the newest one and copy
# it to the canonical squad.json path.
SQUAD_FILE=""
for f in "$PACTO_GOV_DIR/deployments/31337"/squad-*.json; do
  if [ -f "$f" ] && { [ -z "$SQUAD_FILE" ] || [ "$f" -nt "$SQUAD_FILE" ]; }; then
    SQUAD_FILE="$f"
  fi
done
if [ -z "$SQUAD_FILE" ] || [ ! -f "$SQUAD_FILE" ]; then
  err "Expected squad deployment artifact not found under $PACTO_GOV_DIR/deployments/31337/"
  exit 1
fi

copy_artifact_with_docker "$SQUAD_FILE" "$SQUAD_ARTIFACT"

# Resolve and bootstrap the initial crew members. We do this after the
# artifact is copied because the Quartermaster address is required.
resolve_crew_members
QUARTERMASTER_ADDRESS="$(jq -r '.quartermaster' "$SQUAD_ARTIFACT")"
if [ -n "$QUARTERMASTER_ADDRESS" ] && [ "$QUARTERMASTER_ADDRESS" != "null" ]; then
  bootstrap_crew "$QUARTERMASTER_ADDRESS"
  append_crew_to_artifact "$SQUAD_ARTIFACT"
else
  err "Quartermaster address missing from squad artifact; cannot bootstrap crew."
  exit 1
fi

echo "Squad deployment complete."
echo "Artifact: $SQUAD_ARTIFACT"
echo "Crew members:"
jq -r '.crewMembers[] | "  - \(.bot_id // "explicit"): \(.address)"' "$SQUAD_ARTIFACT" 2>/dev/null || true
jq . "$SQUAD_ARTIFACT" 2>/dev/null || true

# Fix artifact ownership so the host user can read/write deployment files.
if [ -d "$DEPLOYMENTS_DIR" ]; then
  echo "Fixing artifact ownership for host user $(id -u):$(id -g)..."
  docker run --rm \
    -v "$DEPLOYMENTS_DIR:/dst" \
    --entrypoint chown \
    alpine:latest \
    -R "$(id -u):$(id -g)" /dst
fi
