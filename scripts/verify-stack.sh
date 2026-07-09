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

get_version() {
  local service="$1" command="$2" flag output
  shift 2
  for flag in "$@"; do
    if output=$(docker compose exec -T "$service" "$command" "$flag" 2>/dev/null); then
      echo "$output" | head -1 | tr -d '\r'
      return 0
    fi
  done
  return 1
}

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
  local version
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

  version=$(get_version anvil anvil --version)
  if [ -n "$version" ]; then
    pass "anvil version: $version"
  fi

  if command -v cast >/dev/null 2>&1; then
    if cast block-number --rpc-url http://localhost:8545 >/dev/null 2>&1; then
      pass "anvil RPC responds on http://localhost:8545"
    else
      fail "anvil RPC is not responding on http://localhost:8545"
    fi

    if cast block-number --rpc-url https://localhost:8546 --insecure >/dev/null 2>&1; then
      pass "anvil RPC responds over HTTPS on https://localhost:8546"
    else
      fail "anvil RPC is not responding over HTTPS on https://localhost:8546"
    fi
  else
    warn "cast not found in PATH; skipping RPC probe"
  fi
}

check_nostr_relay() {
  local version
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

  version=$(get_version nostr-relay ./nostr-rs-relay --version -V)
  if [ -n "$version" ]; then
    pass "nostra version: $version"
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
    if printf '[]\n' | websocat -k -1 wss://localhost:7001 2>/dev/null | cat >/dev/null; then
      pass "caddy TLS sidecar responds on wss://localhost:7001"
    else
      fail "caddy TLS sidecar is not responding on wss://localhost:7001"
    fi
  else
    warn "websocat not found in PATH; skipping wss:// check"
  fi
}

pacto_bot_api_version() {
  local body
  if body=$(docker compose exec -T pacto-bot-api perl -MIO::Socket::INET -e '
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:9800", Timeout => 5) or exit 1;
    print $s "GET /version HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n";
    my $body = "";
    while (<$s>) { $body .= $_ }
    close $s;
    $body =~ s/.*\r?\n\r?\n//s;
    print $body;
  ' 2>/dev/null); then
    echo "$body" | jq -r 'if .version then "pacto-bot-api \(.version) (\(.git_sha // "unknown"))" else empty end' 2>/dev/null
  fi
}

pacto_bot_api_socket_path() {
  local config_text socket_path
  config_text=$(docker compose exec -T pacto-bot-api cat /etc/pacto/pacto-bot-api.toml 2>/dev/null || true)
  socket_path=$(printf '%s\n' "$config_text" | grep -E '^[[:space:]]*socket_path[[:space:]]*=' | head -1 | cut -d'=' -f2- | sed -e "s/^[[:space:]]*//; s/[[:space:]]*$//; s/^\"//; s/\"$//; s/^'//; s/'$//")
  if [ -n "$socket_path" ]; then
    echo "$socket_path"
  else
    # Daemon default when socket_path is not configured.
    echo "/var/lib/pacto-bot-api/.local/share/pacto-bot-api/pacto-bot-api.sock"
  fi
}

check_pacto_bot_api() {
  local socket_path version
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

  version=$(pacto_bot_api_version)
  if [ -n "$version" ]; then
    pass "pacto-bot-api version: $version"
  fi

  socket_path=$(pacto_bot_api_socket_path)
  if docker compose exec pacto-bot-api test -S "$socket_path" >/dev/null 2>&1; then
    pass "pacto-bot-api socket is present at $socket_path"
  else
    fail "pacto-bot-api socket is missing at $socket_path"
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
