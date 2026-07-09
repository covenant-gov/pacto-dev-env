#!/usr/bin/env bash
set -euo pipefail

# Headless wrapper to create or re-open an MLS group and invite a bot.
#
# Usage:
#   PACTO_MLS_CREATOR_NSEC=nsec1... BOT_NPUB=npub1... GROUP_NAME=local-dev-squad \
#     ./scripts/create-mls-group.sh
#
# Or with a nsec file:
#   PACTO_MLS_CREATOR_NSEC_FILE=/path/to/nsec.txt BOT_NPUB=npub1... \
#     GROUP_NAME=local-dev-squad ./scripts/create-mls-group.sh
#
# Required environment variables:
#   BOT_NPUB              - the bot's Nostr public key (hex or bech32 npub)
#   GROUP_NAME            - the human-readable group idempotency key
#   PACTO_MLS_CREATOR_NSEC - the creator's nsec (or use PACTO_MLS_CREATOR_NSEC_FILE)
#
# Optional environment variables:
#   PACTO_MLS_CREATOR_NSEC_FILE - path to a file containing the creator nsec

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

err() { echo -e "${RED}[create-mls-group]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[create-mls-group]${NC} $*"; }

docker_compose() {
  docker compose -f "$REPO_ROOT/docker-compose.yml" "$@"
}

require_env() {
  local var="$1"
  if [ -z "${!var:-}" ]; then
    err "$var is required"
    return 1
  fi
}

# Resolve the creator nsec from the env var or file.
PACTO_MLS_CREATOR_NSEC="${PACTO_MLS_CREATOR_NSEC:-}"
PACTO_MLS_CREATOR_NSEC_FILE="${PACTO_MLS_CREATOR_NSEC_FILE:-}"

if [ -z "$PACTO_MLS_CREATOR_NSEC" ] && [ -n "$PACTO_MLS_CREATOR_NSEC_FILE" ]; then
  if [ ! -f "$PACTO_MLS_CREATOR_NSEC_FILE" ]; then
    err "nsec file not found: $PACTO_MLS_CREATOR_NSEC_FILE"
    exit 1
  fi
  PACTO_MLS_CREATOR_NSEC="$(tr -d '[:space:]' < "$PACTO_MLS_CREATOR_NSEC_FILE")"
fi

if [ -z "$PACTO_MLS_CREATOR_NSEC" ]; then
  err "Set PACTO_MLS_CREATOR_NSEC or PACTO_MLS_CREATOR_NSEC_FILE"
  exit 1
fi

require_env BOT_NPUB
require_env GROUP_NAME

# Default to the container's internal relay and state paths. The binary inside
# the image uses the same defaults, so this is mostly documentation.
RELAY="ws://nostr-relay:8080"
STATE_FILE="/data/deployments/31337/.mls-groups.json"
MLS_DB="/data/deployments/31337/.mls-creator.db"

exec docker_compose exec \
  -e PACTO_MLS_CREATOR_NSEC \
  pacto-bot-api \
  create-mls-group \
  --bot-npub "$BOT_NPUB" \
  --group-name "$GROUP_NAME" \
  --relay "$RELAY" \
  --state-file "$STATE_FILE" \
  --mls-db "$MLS_DB"
