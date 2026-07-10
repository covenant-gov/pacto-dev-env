#!/usr/bin/env bash
set -euo pipefail

# Publish a KeyPackage for a bot by registering a temporary handler and calling
# agent.publish_key_package over the daemon Unix socket.
#
# Usage:
#   BOT_ID=captain ./scripts/publish-key-package.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BOT_ID="${BOT_ID:-}"
if [ -z "$BOT_ID" ]; then
  echo "[publish-key-package] BOT_ID is required" >&2
  exit 1
fi

if ! docker compose -f "$REPO_ROOT/docker-compose.yml" ps pacto-bot-api --status running | grep -q "pacto-bot-api"; then
  echo "[publish-key-package] pacto-bot-api container is not running" >&2
  exit 1
fi

exec docker run --rm \
  -v pacto-bot-api-data:/var/lib/pacto-bot-api \
  -e BOT_ID="$BOT_ID" \
  -e PACTO_SOCKET_PATH="/var/lib/pacto-bot-api/pacto-bot-api.sock" \
  -v "$SCRIPT_DIR/publish_key_package.py:/publish_key_package.py:ro" \
  python:3-slim \
  python /publish_key_package.py
