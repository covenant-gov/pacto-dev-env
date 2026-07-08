#!/usr/bin/env bash
set -euo pipefail

# Seed a Nave Pirata squad on the local Anvil testnet.
#
# Usage:
#   ./scripts/seed-squad.sh
#
# Required environment variables:
#   PACTO_SQUAD_CAPTAIN_NPUB  - captain Nostr public key (hex or bech32 npub)
#   PACTO_SQUAD_CANDIDATE_NPUB - candidate Nostr public key (hex or bech32 npub)
#
# Optional environment variables:
#   PACTO_GOV_DIR        - path to pacto-gov repo (default: ../pacto-gov)
#   ANVIL_RPC_URL        - Anvil RPC endpoint (default: http://localhost:8545)
#   ANVIL_PRIVATE_KEY    - deployer private key
#                          (default: Anvil account #0)
#   PACTO_SQUAD_METADATA_URI - metadata URI for the squad (default: ipfs://Qmdummy)
#   FORCE_SEED_SQUAD     - set to 1 to re-deploy when squad.json already exists
#
# If the required env vars are missing, the script prints explicit
# `pacto-bot-admin new` instructions and exits with status 1.

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

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

err() { echo -e "${RED}[seed-squad]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[seed-squad]${NC} $*"; }

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
  [ -f "$CONFIG_FILE" ] || return 0
  awk -F'"' -v bot_id="$bot_id" '
    /^\[\[/ { in_bots=0 }
    /^\[\[bots\]\]/ { in_bots=1; id=""; npub="" }
    in_bots && /^id = / { id=$2 }
    in_bots && /^npub = / { npub=$2 }
    in_bots && id == bot_id && npub != "" { print npub; exit }
  ' "$CONFIG_FILE"
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

echo "Waiting for Anvil at $ANVIL_RPC_URL..."
for _ in $(seq 1 30); do
  if cast block-number --rpc-url "$ANVIL_RPC_URL" >/dev/null 2>&1; then
    echo "Anvil is ready."
    break
  fi
  sleep 1
done

cast block-number --rpc-url "$ANVIL_RPC_URL" >/dev/null

echo "Deploying Nave Pirata squad to Anvil (chain ID 31337)..."
echo "  captain:  $CAPTAIN_ADDRESS"
echo "  factory:  $NAVE_PIRATA_FACTORY"
echo "  metadata: $SQUAD_METADATA_URI"

(
  cd "$PACTO_GOV_DIR"
  NAVE_PIRATA_FACTORY="$NAVE_PIRATA_FACTORY" \
    CAPTAIN="$CAPTAIN_ADDRESS" \
    SQUAD_METADATA_URI="$SQUAD_METADATA_URI" \
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

cp "$SQUAD_FILE" "$SQUAD_ARTIFACT"
echo "Squad deployment complete."
echo "Artifact: $SQUAD_ARTIFACT"
jq . "$SQUAD_ARTIFACT" 2>/dev/null || true
