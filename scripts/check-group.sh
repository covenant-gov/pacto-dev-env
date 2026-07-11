#!/usr/bin/env bash
set -euo pipefail

# Report the MLS group artifact and daemon DB state.
#
# Usage:
#   ./scripts/check-group.sh [BOT_ID]
#   SHOW_DB=1 ./scripts/check-group.sh [BOT_ID]
#   ./scripts/check-group.sh --db-only BOT_ID

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DB_ONLY=0
if [ "${1:-}" = "--db-only" ]; then
  DB_ONLY=1
  shift
fi

BOT_ID="${1:-${BOT_ID:-}}"
DEPLOYMENTS_DIR="$REPO_ROOT/data/deployments/31337"
SHOW_DB="${SHOW_DB:-0}"

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

warn() { echo -e "${YELLOW}[check-group]${NC} $*"; }
ok() { echo -e "${GREEN}[check-group]${NC} $*"; }

# Print an artifact file, falling back to a container read if it is root-owned.
cat_artifact() {
  local artifact="$1"
  if jq . "$artifact" 2>/dev/null; then
    return 0
  fi
  warn "Host read failed; reading artifact through a container as root..."
  docker run --rm \
    -v "$artifact:/artifact.json:ro" \
    --entrypoint cat \
    alpine:latest \
    /artifact.json
}

if [ -z "$BOT_ID" ]; then
  # If no bot id is supplied, report every artifact found.
  if [ -d "$DEPLOYMENTS_DIR" ]; then
    found=0
    for artifact in "$DEPLOYMENTS_DIR"/group-*.json; do
      [ -f "$artifact" ] || continue
      found=1
      id="$(basename "$artifact" .json | sed 's/^group-//')"
      ok "Artifact: $artifact"
      cat_artifact "$artifact"
      echo
      if [ "$SHOW_DB" -eq 1 ]; then
        "$0" --db-only "$id"
      fi
    done
    if [ "$found" -eq 0 ]; then
      warn "No group artifacts found in $DEPLOYMENTS_DIR"
    fi
  else
    warn "Deployments directory not found: $DEPLOYMENTS_DIR"
  fi
  exit 0
fi

if [ "$DB_ONLY" -eq 1 ]; then
  ARTIFACT="$DEPLOYMENTS_DIR/group-$BOT_ID.json"
  if [ ! -f "$ARTIFACT" ]; then
    warn "Artifact not found: $ARTIFACT"
  fi
  if [ "$SHOW_DB" -ne 1 ]; then
    exit 0
  fi
else
  ARTIFACT="$DEPLOYMENTS_DIR/group-$BOT_ID.json"
  if [ -f "$ARTIFACT" ]; then
    ok "Artifact: $ARTIFACT"
    cat_artifact "$ARTIFACT"
  else
    warn "Artifact not found: $ARTIFACT"
  fi

  if [ "$SHOW_DB" -ne 1 ]; then
    exit 0
  fi
  echo
fi

warn "Daemon MLS database state for bot '$BOT_ID':"
if ! docker compose -f "$REPO_ROOT/docker-compose.yml" ps pacto-bot-api --status running | grep -q "pacto-bot-api"; then
  warn "pacto-bot-api container is not running; cannot query DB state"
  exit 0
fi

# The daemon stores the MLS DB per bot under the configured mls_db_path.
# We infer the directory from the config file so the check stays accurate.
CONFIG_FILE="$REPO_ROOT/pacto-bot-api.toml"
if [ -f "$CONFIG_FILE" ]; then
  MLS_DB="$(awk '/^\[\[bots\]\]/{in_bot=1; target=0; next} in_bot && /^id = "'"$BOT_ID"'"$/{target=1} in_bot && target && /^mls_db_path = /{gsub(/^.*= "|"$/,""); print; exit}' "$CONFIG_FILE")"
fi

if [ -z "$MLS_DB" ]; then
  warn "Could not infer mls_db_path for bot '$BOT_ID' from $CONFIG_FILE"
  exit 0
fi

docker run --rm -v pacto-bot-api-data:/var/lib/pacto-bot-api:ro alpine:3.19 sh -c \
  "if [ -f '$MLS_DB' ]; then apk add -q sqlite && sqlite3 '$MLS_DB' '.headers on' '.mode column' 'SELECT name, description, admin_pubkeys, last_message_id, last_message_at, epoch, state FROM groups;' ; else echo 'No MLS database at $MLS_DB'; fi"
