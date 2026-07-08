#!/usr/bin/env bash
set -euo pipefail

# Ensure the canonical Hats Protocol and Safe v1.4.1 singletons are present on
# the local Anvil node. `pacto-gov` scripts assume these contracts exist at their
# mainnet addresses, but a fresh Anvil chain does not have them. This script uses
# `anvil_setCode` to load deterministic runtime bytecode so local deployments work
# without requiring a mainnet fork or a live RPC.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANVIL_RPC_URL="${ANVIL_RPC_URL:-http://localhost:8545}"

HATS_ADDRESS="0x3bc1A0Ad72417f2d411118085256fC53CBdDd137"
SAFE_SINGLETON_ADDRESS="0x41675C099F32341bf84BFc5382aF534df5C7461a"
SAFE_PROXY_FACTORY_ADDRESS="0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67"

BYTECODE_DIR="${PACTO_BYTECODE_DIR:-$SCRIPT_DIR/bytecode}"

wait_for_anvil() {
  echo "Waiting for Anvil at $ANVIL_RPC_URL..."
  for _ in $(seq 1 30); do
    if cast block-number --rpc-url "$ANVIL_RPC_URL" >/dev/null 2>&1; then
      echo "Anvil is ready."
      return 0
    fi
    sleep 1
  done
  echo "Anvil did not become available at $ANVIL_RPC_URL" >&2
  exit 1
}

ensure_code() {
  local addr="$1"
  local name="$2"
  local file="$3"

  if [ ! -f "$file" ]; then
    echo "Missing bytecode file: $file" >&2
    exit 1
  fi

  local current
  current="$(cast code "$addr" --rpc-url "$ANVIL_RPC_URL" 2>/dev/null || true)"
  if [ -n "$current" ] && [ "$current" != "0x" ]; then
    echo "$name already has code at $addr; skipping."
    return 0
  fi

  echo "Setting $name bytecode at $addr..."
  cast rpc anvil_setCode "$addr" "$(cat "$file")" --rpc-url "$ANVIL_RPC_URL" >/dev/null
  echo "$name bytecode set."
}

wait_for_anvil
ensure_code "$HATS_ADDRESS" "Hats" "$BYTECODE_DIR/anvil-hats.bin"
ensure_code "$SAFE_SINGLETON_ADDRESS" "Safe singleton" "$BYTECODE_DIR/anvil-safe-singleton.bin"
ensure_code "$SAFE_PROXY_FACTORY_ADDRESS" "Safe proxy factory" "$BYTECODE_DIR/anvil-safe-proxy-factory.bin"
echo "External contracts ready."
