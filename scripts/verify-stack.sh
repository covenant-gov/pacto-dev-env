#!/usr/bin/env bash
set -euo pipefail

# Pacto dev-env stack health checker.
#
# Verifies that the running Docker Compose services are up and reachable from
# the host. Default services are always checked; optional services (aztec,
# bunker) are only checked when they are part of the running project.

export PATH="$HOME/.foundry/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

failed=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; failed=1; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }

service_state() {
  local raw
  raw=$(docker compose ps --format json "$1" 2>/dev/null)
  echo "$raw" | jq -r 'if type == "array" then .[0].State else .State end // "missing"'
}

service_health() {
  local raw
  raw=$(docker compose ps --format json "$1" 2>/dev/null)
  echo "$raw" | jq -r 'if type == "array" then .[0].Health else .Health end // "unknown"'
}

check_anvil() {
  echo "Checking anvil..."
  if [ "$(service_state anvil)" != "running" ]; then
    fail "anvil container is not running"
    return
  fi

  if [ "$(service_health anvil)" = "healthy" ]; then
    pass "anvil container is healthy"
  else
    warn "anvil container is running but not yet healthy"
  fi

  if command -v cast >/dev/null 2>&1; then
    if cast block-number --rpc-url http://localhost:8545 >/dev/null 2>&1; then
      pass "anvil RPC responds on http://localhost:8545"
    else
      fail "anvil RPC is not responding on http://localhost:8545"
    fi
  else
    warn "cast not found in PATH; skipping RPC probe"
  fi
}

check_nostr_relay() {
  echo "Checking nostr-relay..."
  if [ "$(service_state nostr-relay)" != "running" ]; then
    fail "nostr-relay container is not running"
    return
  fi

  if [ "$(service_health nostr-relay)" = "healthy" ]; then
    pass "nostr-relay container is healthy"
  else
    warn "nostr-relay container is running but not yet healthy"
  fi

  if curl -sS http://localhost:7000 >/dev/null 2>&1; then
    pass "nostr-relay responds on http://localhost:7000"
  else
    fail "nostr-relay is not responding on http://localhost:7000"
  fi
}

check_caddy() {
  echo "Checking caddy TLS sidecar..."
  if [ "$(service_state caddy)" != "running" ]; then
    warn "caddy TLS sidecar is not running"
    return
  fi

  if [ "$(service_health caddy)" = "healthy" ]; then
    pass "caddy container is healthy"
  else
    warn "caddy container is running but not yet healthy"
  fi

  if command -v websocat >/dev/null 2>&1; then
    if websocat -k -1 wss://localhost:7001 </dev/null >/dev/null 2>&1; then
      pass "caddy TLS sidecar responds on wss://localhost:7001"
    else
      fail "caddy TLS sidecar is not responding on wss://localhost:7001"
    fi
  else
    warn "websocat not found in PATH; skipping wss:// check"
  fi
}

check_pacto_bot_api() {
  echo "Checking pacto-bot-api..."
  if [ "$(service_state pacto-bot-api)" != "running" ]; then
    fail "pacto-bot-api container is not running"
    return
  fi

  if [ "$(service_health pacto-bot-api)" = "healthy" ]; then
    pass "pacto-bot-api container is healthy"
  else
    warn "pacto-bot-api container is running but not yet healthy"
  fi

  if docker compose exec pacto-bot-api test -S /var/lib/pacto-bot-api/pacto-bot-api.sock >/dev/null 2>&1; then
    pass "pacto-bot-api socket is present"
  else
    fail "pacto-bot-api socket is missing"
  fi
}

check_aztec() {
  echo "Checking aztec-sandbox..."
  if [ "$(service_state aztec-sandbox)" != "running" ]; then
    fail "aztec-sandbox container is not running"
    return
  fi

  if [ "$(service_health aztec-sandbox)" = "healthy" ]; then
    pass "aztec-sandbox container is healthy"
  else
    warn "aztec-sandbox container is running but not yet healthy"
  fi

  if curl -fsS http://localhost:8080/status >/dev/null 2>&1; then
    pass "aztec-sandbox responds on http://localhost:8080/status"
  else
    fail "aztec-sandbox is not responding on http://localhost:8080/status"
  fi
}

check_bunker() {
  echo "Checking nip46-bunker..."
  if [ "$(service_state nip46-bunker)" != "running" ]; then
    fail "nip46-bunker container is not running"
    return
  fi

  if [ "$(service_health nip46-bunker)" = "healthy" ]; then
    pass "nip46-bunker container is healthy"
  else
    warn "nip46-bunker container is running but not yet healthy"
  fi

  if curl -fsS http://localhost:3001/api/auth/config >/dev/null 2>&1; then
    pass "nip46-bunker responds on http://localhost:3001/api/auth/config"
  else
    fail "nip46-bunker is not responding on http://localhost:3001/api/auth/config"
  fi
}

main() {
  echo "Pacto dev-env stack verification"
  echo "================================"

  if ! command -v docker >/dev/null 2>&1; then
    fail "docker is not installed or not in PATH"
    exit 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    fail "docker compose plugin is not available"
    exit 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    fail "jq is required but not found in PATH"
    exit 1
  fi

  check_anvil
  check_nostr_relay
  check_caddy
  check_pacto_bot_api

  # Optional services are checked only when they are running.
  running_services=$(docker compose ps --services 2>/dev/null || true)
  if echo "$running_services" | grep -q '^aztec-sandbox$'; then
    check_aztec
  fi
  if echo "$running_services" | grep -q '^nip46-bunker$'; then
    check_bunker
  fi

  echo
  if [ "$failed" -eq 0 ]; then
    echo -e "${GREEN}All checks passed.${NC}"
    exit 0
  else
    echo -e "${RED}Some checks failed.${NC}"
    exit 1
  fi
}

main "$@"
