#!/usr/bin/env bash
set -euo pipefail

# Headless wrapper to create an MLS group using the admin CLI built into the
# pacto-bot-api image.
#
# The standalone `create-mls-group` binary was replaced by the
# `pacto-bot-admin mls-group` subcommand. This script invokes that subcommand
# inside the running container and writes the returned group wire ID to an
# artifact file.
#
# Usage:
#   BOT_ID=bosun GROUP_NAME=local-dev-squad RECIPIENT_NPUB=npub1... \
#     make create-mls-group
#
# Required environment variables:
#   RECIPIENT_NPUB - the Nostr public key (hex or bech32 npub) of the other
#                    initial group member. If this is a bot configured in
#                    pacto-bot-api.toml with SendGroupMessages, a KeyPackage is
#                    published automatically when one is not already on the
#                    relay.
#
# Optional environment variables:
#   BOT_ID      - the bot identity from pacto-bot-api.toml that owns the group
#                 (default: bosun). Must have the `Admin` capability and an
#                 MLS engine configured (`mls_db_path`).
#   GROUP_NAME  - the human-readable group name (default: local-dev-squad)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

err() { echo -e "${RED}[create-mls-group]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[create-mls-group]${NC} $*" >&2; }
ok() { echo -e "${GREEN}[create-mls-group]${NC} $*"; }

require_env() {
  local var="$1"
  if [ -z "${!var:-}" ]; then
    err "$var is required"
    exit 1
  fi
}

BOT_ID="${BOT_ID:-bosun}"
GROUP_NAME="${GROUP_NAME:-local-dev-squad}"
RECIPIENT_NPUB="${RECIPIENT_NPUB:-}"

require_env RECIPIENT_NPUB

CONFIG_FILE="$REPO_ROOT/pacto-bot-api.toml"
DEPLOYMENTS_DIR="$REPO_ROOT/data/deployments/31337"
ARTIFACT="$DEPLOYMENTS_DIR/group-$BOT_ID.json"

if [ ! -f "$CONFIG_FILE" ]; then
  err "Missing $CONFIG_FILE. Run 'make config' first."
  exit 1
fi

if ! grep -q "^id = \"$BOT_ID\"$" "$CONFIG_FILE" 2>/dev/null; then
  err "Bot '$BOT_ID' not found in $CONFIG_FILE"
  exit 1
fi

# Sanity check that the creator bot has the Admin capability and an MLS engine.
if ! awk '/^\[\[bots\]\]/{in_bot=1; target=0; next} in_bot && /^id = "'"$BOT_ID"'"$/{target=1} in_bot && target && /capabilities = /{if ($0 !~ /Admin/) {exit 1}}' "$CONFIG_FILE"; then
  err "Bot '$BOT_ID' is missing the 'Admin' capability required for mls-group create"
  exit 1
fi
if ! awk '/^\[\[bots\]\]/{in_bot=1; target=0; next} in_bot && /^id = "'"$BOT_ID"'"$/{target=1} in_bot && target && /^mls_db_path = /{found=1} END{exit found ? 0 : 1}' "$CONFIG_FILE"; then
  err "Bot '$BOT_ID' is missing an MLS engine (mls_db_path) in $CONFIG_FILE"
  exit 1
fi

# Resolve the bot_id (if any) matching the recipient pubkey.
if ! python3 "$SCRIPT_DIR/find_bot_by_pubkey.py" "$CONFIG_FILE" "$RECIPIENT_NPUB" >/tmp/create-mls-recipient.json 2>/dev/null; then
  warn "Could not normalize recipient pubkey; continuing without bot auto-detection"
  RECIPIENT_BOT_ID=""
else
  RECIPIENT_BOT_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("bot_id",""))' </tmp/create-mls-recipient.json)"
fi
rm -f /tmp/create-mls-recipient.json

docker_compose() {
  docker compose -f "$REPO_ROOT/docker-compose.yml" "$@"
}

if ! docker compose ps pacto-bot-api --status running | grep -q "pacto-bot-api"; then
  err "pacto-bot-api container is not running. Run 'make up' first."
  exit 1
fi

query_key_package() {
  local timeout="${1:-30}"
  docker run --rm \
    --network pacto \
    -e RELAY_URL="ws://nostr-relay:8080" \
    -e AUTHOR="$RECIPIENT_NPUB" \
    -e TIMEOUT="$timeout" \
    -v "$SCRIPT_DIR/query_key_package.py:/query.py:ro" \
    python:3-slim \
    sh -c "pip install -q --root-user-action=ignore websockets && python /query.py"
}

key_package_found() {
  local output
  output="$(query_key_package 5)"
  python3 -c 'import json,sys; print(json.load(sys.stdin).get("found",False))' <<< "$output" | grep -q "True"
}

# If the recipient is a configured bot, ensure it has a fresh KeyPackage on
# the relay.  We always publish one for a configured bot because the daemon's
# MLS group creation path requires a recently-published KeyPackage.
if [ -n "$RECIPIENT_BOT_ID" ]; then
  warn "Recipient '$RECIPIENT_NPUB' matches bot '$RECIPIENT_BOT_ID'"
  if key_package_found; then
    warn "KeyPackage already on relay for '$RECIPIENT_BOT_ID'; publishing a fresh one..."
  else
    warn "No KeyPackage on relay for '$RECIPIENT_BOT_ID'; publishing one..."
  fi
  if ! BOT_ID="$RECIPIENT_BOT_ID" "$SCRIPT_DIR/publish-key-package.sh" >/dev/null; then
    err "Failed to publish KeyPackage for '$RECIPIENT_BOT_ID'"
    err "Ensure the bot has the SendGroupMessages capability and mls_db_path in $CONFIG_FILE"
    exit 1
  fi
fi

# Poll until the recipient's KeyPackage is visible on the relay.
warn "Waiting for KeyPackage on relay for '$RECIPIENT_NPUB'..."
if ! key_package_found 30; then
  err "Timed out waiting for a KeyPackage (kind:443) for '$RECIPIENT_NPUB' on the relay"
  exit 1
fi
ok "KeyPackage found on relay."

warn "Creating MLS group '$GROUP_NAME' owned by bot '$BOT_ID' and inviting '$RECIPIENT_NPUB'..."
WIRE_ID="$(docker_compose exec -T pacto-bot-api \
  pacto-bot-admin \
  -c /etc/pacto/pacto-bot-api.toml \
  -d /var/lib/pacto-bot-api \
  mls-group create \
  --bot "$BOT_ID" \
  --group "$GROUP_NAME" \
  --recipient "$RECIPIENT_NPUB" | tr -d '[:space:]')"

if [ -z "$WIRE_ID" ]; then
  err "pacto-bot-admin mls-group create did not return a group wire ID"
  exit 1
fi

# Ensure the deployments directory exists, creating through a container if it is
# root-owned (e.g. from earlier seed scripts).
if [ ! -d "$DEPLOYMENTS_DIR" ]; then
  if ! mkdir -p "$DEPLOYMENTS_DIR" 2>/dev/null; then
    warn "Creating root-owned deployments directory via container..."
    docker run --rm \
      -v "$REPO_ROOT/data:/data" \
      --entrypoint mkdir \
      alpine:latest \
      -p "/data/deployments/31337"
  fi
fi

ARTIFACT_JSON="$(cat <<EOF
{
  "group_id": "$WIRE_ID",
  "bot_id": "$BOT_ID",
  "group_name": "$GROUP_NAME",
  "recipient_npub": "$RECIPIENT_NPUB",
  "relay": "ws://nostr-relay:8080"
}
EOF
)"

if echo "$ARTIFACT_JSON" > "$ARTIFACT" 2>/dev/null; then
  ok "Wrote artifact: $ARTIFACT"
else
  warn "Host write failed; writing artifact through a container as root..."
  TMP_FILE="$(mktemp)"
  echo "$ARTIFACT_JSON" > "$TMP_FILE"
  docker run --rm \
    -v "$TMP_FILE:/tmp/group.json:ro" \
    -v "$DEPLOYMENTS_DIR:/dst" \
    --entrypoint cp \
    alpine:latest \
    /tmp/group.json "/dst/$(basename "$ARTIFACT")"
  rm -f "$TMP_FILE"
  docker run --rm \
    -v "$DEPLOYMENTS_DIR:/dst" \
    --entrypoint chown \
    alpine:latest \
    "$(id -u):$(id -g)" "/dst/$(basename "$ARTIFACT")"
  ok "Wrote artifact: $ARTIFACT"
fi

ok "Group ID: $WIRE_ID"
echo "$WIRE_ID"
