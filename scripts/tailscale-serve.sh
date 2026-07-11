#!/usr/bin/env bash
set -euo pipefail

# Expose Anvil EVM and the Nostr relay over your Tailscale tailnet.
# This lets you access the dev stack from another tailnet device without
# changing the Docker Compose localhost-only port bindings.

cd "$(dirname "$0")/.."

EVM_PORT="${TAILSCALE_EVM_PORT:-8545}"
RELAY_PORT="${TAILSCALE_RELAY_PORT:-7001}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <start|stop|status|env>

  start   Expose Anvil and Nostr relay over Tailscale
  stop    Stop exposing them
  status  Show current Tailscale serve configuration
  env     Print the Pacto env block to use from a remote device

Default ports (override with env vars):
  EVM RPC:     TAILSCALE_EVM_PORT=${EVM_PORT}
  Nostr relay: TAILSCALE_RELAY_PORT=${RELAY_PORT}
EOF
}

require_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "tailscale is not installed. Install it from https://tailscale.com/download"
    exit 1
  fi

  if ! tailscale status >/dev/null 2>&1; then
    echo "Tailscale is not running. Start it with: tailscale up"
    exit 1
  fi
}

# Best-effort detection of the tailnet FQDN. Falls back to the Tailscale IP if
# the JSON output cannot be parsed.
tailscale_machine() {
  local dns_name=""

  if command -v python3 >/dev/null 2>&1; then
    dns_name=$(tailscale status --json 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["Self"].get("DNSName","").rstrip("."))' 2>/dev/null || true)
  fi

  if [ -z "$dns_name" ]; then
    dns_name=$(tailscale status --self 2>/dev/null | awk 'NR==1 {print $1}' | sed 's/\.$//')
  fi

  echo "$dns_name"
}

start() {
  require_tailscale

  echo "[tailscale-serve] Exposing services on your tailnet..."
  echo "  EVM RPC:     https://<machine>:${EVM_PORT}  -> http://localhost:8545"
  echo "  Nostr relay: wss://<machine>:${RELAY_PORT}  -> http://localhost:7000"
  echo

  tailscale serve --https="${EVM_PORT}" http://localhost:8545
  tailscale serve --https="${RELAY_PORT}" http://localhost:7000

  echo
  echo "[tailscale-serve] Done."
  print_env
}

stop() {
  require_tailscale

  echo "[tailscale-serve] Removing tailnet exposure..."
  tailscale serve --https="${EVM_PORT}" off
  tailscale serve --https="${RELAY_PORT}" off
}

status() {
  require_tailscale
  tailscale serve status
}

print_env() {
  local machine
  machine=$(tailscale_machine)

  echo "Use these settings on a remote tailnet device:"
  echo
  echo "  export PACTO_RPC_URL=https://${machine}:${EVM_PORT}"
  echo "  export PACTO_RELAY_URL=wss://${machine}:${RELAY_PORT}"
  echo "  export PACTO_CHAIN_ID=31337"
  echo
  echo "If the hostname above is empty, replace it with the machine name from:"
  echo "  tailscale status"
}

case "${1:-status}" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  status)
    status
    ;;
  env)
    print_env
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "Unknown command: ${1:-}" >&2
    usage >&2
    exit 1
    ;;
esac
