#!/usr/bin/env bash
set -euo pipefail

# Print Pacto connection instructions using the SSL endpoints exposed by Caddy.
# All services that do not natively speak TLS are reverse-proxied through
# Caddy so Pacto can use wss:// and https:// URLs.

cd "$(dirname "$0")/.."

HOST_RELAY_WSS_PORT=7001
HOST_ANVIL_HTTPS_PORT=8546
HOST_AZTEC_HTTPS_PORT=8445
HOST_BUNKER_HTTPS_PORT=8446

if ! docker compose ps >/dev/null 2>&1; then
  echo "The dev stack does not appear to be running. Start it with:"
  echo "  make up"
  exit 1
fi

running_services=$(docker compose ps --services 2>/dev/null || true)

aztec_running=false
bunker_running=false
if echo "$running_services" | grep -q '^aztec-sandbox$'; then
  aztec_running=true
fi
if echo "$running_services" | grep -q '^nip46-bunker$'; then
  bunker_running=true
fi

echo "Connect Pacto to this dev setup with the following endpoints:"
echo
printf "  %-16s %s\n" "Nostr relay:" "wss://localhost:${HOST_RELAY_WSS_PORT}"
printf "  %-16s %s\n" "EVM RPC:" "https://localhost:${HOST_ANVIL_HTTPS_PORT}"
printf "  %-16s %s\n" "Chain ID:" "31337"
printf "  %-16s %s\n" "Daemon socket:" "/var/lib/pacto-bot-api/pacto-bot-api.sock"

if [ "$aztec_running" = true ]; then
  printf "  %-16s %s\n" "Aztec sandbox:" "https://localhost:${HOST_AZTEC_HTTPS_PORT}"
else
  printf "  %-16s %s\n" "Aztec sandbox:" "https://localhost:${HOST_AZTEC_HTTPS_PORT} (not running — docker compose --profile aztec up -d)"
fi

if [ "$bunker_running" = true ]; then
  printf "  %-16s %s\n" "NIP-46 bunker:" "https://localhost:${HOST_BUNKER_HTTPS_PORT}"
else
  printf "  %-16s %s\n" "NIP-46 bunker:" "https://localhost:${HOST_BUNKER_HTTPS_PORT} (not running — docker compose --profile bunker up -d)"
fi

echo
echo "Copy-paste env block:"
echo "  export PACTO_RELAY_URL=wss://localhost:${HOST_RELAY_WSS_PORT}"
echo "  export PACTO_RPC_URL=https://localhost:${HOST_ANVIL_HTTPS_PORT}"
echo "  export PACTO_CHAIN_ID=31337"
echo "  export PACTO_BOT_API_SOCKET=/var/lib/pacto-bot-api/pacto-bot-api.sock"
if [ "$aztec_running" = true ]; then
  echo "  export PACTO_AZTEC_RPC_URL=https://localhost:${HOST_AZTEC_HTTPS_PORT}"
fi
if [ "$bunker_running" = true ]; then
  echo "  export PACTO_BUNKER_URL=https://localhost:${HOST_BUNKER_HTTPS_PORT}"
  echo "  export COOKIE_SECURE=true"
fi

echo
echo "If Caddy is using its self-signed CA (default when mkcert is not installed),"
echo "clients will need to skip TLS verification. With mkcert installed, run:"
echo "  mkcert -install"
echo "to trust the local CA in browsers and system certificate stores."
