#!/usr/bin/env bash
set -euo pipefail

# Create an MLS squad owned by a bot and invite an identity the way a human
# does: the MLS welcome *plus* the `squad_invite` DM that pacto-app needs to
# turn a joined group into a visible squad.
#
# Why both. A bare MLS welcome joins at the MLS layer and is orphaned at the
# product layer - pacto-app builds squads on the frontend from the DM invite
# payload, so a welcome with no DM leaves the group invisible with no way to
# open it (pacto-app-384.70). Sending the real invite keeps the sandbox on the
# app's own tested join path instead of asking the app to grow a second one.
#
# Usage:
#   RECIPIENT_NPUB=npub1... make invite-squad
#
# Required environment variables:
#   RECIPIENT_NPUB - Nostr public key (hex or bech32) of the identity to invite.
#
# Optional environment variables:
#   BOT_ID     - bot identity from pacto-bot-api.toml that owns the squad
#                (default: bosun). Needs `Admin` and `SendMessages`.
#   SQUAD_NAME - squad name shown in the app (default: local-dev-squad).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

err() { echo -e "${RED}[invite-squad]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[invite-squad]${NC} $*" >&2; }
ok() { echo -e "${GREEN}[invite-squad]${NC} $*"; }

if [ -z "${RECIPIENT_NPUB:-}" ]; then
  err "RECIPIENT_NPUB is required"
  err "Usage: RECIPIENT_NPUB=npub1... make invite-squad"
  exit 1
fi

BOT_ID="${BOT_ID:-bosun}"
SQUAD_NAME="${SQUAD_NAME:-local-dev-squad}"

docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    (cd "$REPO_ROOT" && docker compose "$@")
  else
    (cd "$REPO_ROOT" && docker-compose "$@")
  fi
}

# Group creation, KeyPackage polling and artifact writing already live in
# create-mls-group.sh; this verb only adds the DM.
GROUP_ID="$(BOT_ID="$BOT_ID" GROUP_NAME="$SQUAD_NAME" RECIPIENT_NPUB="$RECIPIENT_NPUB" \
  "$SCRIPT_DIR/create-mls-group.sh" | tail -1)"

if [ -z "$GROUP_ID" ]; then
  err "create-mls-group.sh did not return a group wire ID"
  exit 1
fi

# The inviter's own npub, so the app can attribute the invite.
BOT_NPUB="$(python3 - "$REPO_ROOT/pacto-bot-api.toml" "$BOT_ID" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        cfg = tomllib.load(fh)
except OSError:
    sys.exit(0)
for bot in cfg.get("bots", []):
    if bot.get("id") == sys.argv[2]:
        print(bot.get("npub", ""))
        break
PY
)"

if [ -z "$BOT_NPUB" ]; then
  warn "No npub for bot '$BOT_ID' in pacto-bot-api.toml; sending invite without attribution"
fi

# Shape is pacto-app's `SquadInvitePayload`; `parseSquadInviteMessage` requires
# type, squadName and groupId and ignores unknown fields.
INVITE_JSON="$(python3 - "$SQUAD_NAME" "$GROUP_ID" "$BOT_NPUB" <<'PY'
import json, sys
payload = {"type": "squad_invite", "squadName": sys.argv[1], "groupId": sys.argv[2]}
if sys.argv[3]:
    payload["invitedByNpub"] = sys.argv[3]
print(json.dumps(payload))
PY
)"

warn "Sending squad_invite DM from '$BOT_ID' to '$RECIPIENT_NPUB'..."
DM_EVENT_ID="$(docker_compose exec -T pacto-bot-api \
  pacto-bot-admin \
  -c /etc/pacto/pacto-bot-api.toml \
  -d /var/lib/pacto-bot-api \
  send-test-dm "$BOT_ID" "$RECIPIENT_NPUB" "$INVITE_JSON" | tr -d '[:space:]')"

if [ -z "$DM_EVENT_ID" ]; then
  err "send-test-dm did not return an event id; the invite DM was not published"
  exit 1
fi

ok "Invite DM published: $DM_EVENT_ID"
ok "Squad '$SQUAD_NAME' ready: $GROUP_ID"
echo "$GROUP_ID"
