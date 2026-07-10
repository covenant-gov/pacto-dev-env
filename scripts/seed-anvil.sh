#!/usr/bin/env bash
set -euo pipefail

PACTO_GOV_DIR="${PACTO_GOV_DIR:-/pacto-gov}"
ANVIL_RPC_URL="${ANVIL_RPC_URL:-http://anvil:8545}"
ANVIL_PRIVATE_KEY="${ANVIL_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
FORCE_SEED="${FORCE_SEED:-0}"

cd "$PACTO_GOV_DIR"

if [ ! -f "script/Deploy.sol" ]; then
  echo "error: $PACTO_GOV_DIR does not look like the pacto-gov repository (missing script/Deploy.sol)" >&2
  exit 1
fi

DEPLOYMENTS_DIR="$PACTO_GOV_DIR/deployments/31337"
ARTIFACT="$DEPLOYMENTS_DIR/full-system.json"

# Extract a string field from the pretty-printed JSON artifact without requiring jq.
_json_string_field() {
  local file="$1"
  local key="$2"
  awk -F'"' "/\"$key\"/ {print \$4; exit}" "$file"
}

# Returns 0 if the NavePirataFactory at the recorded address is alive and
# wired to the expected registry, non-zero otherwise.
_factory_is_live() {
  local factory_addr="$1"
  local expected_registry="$2"

  if [ -z "$factory_addr" ] || [ "$factory_addr" = "null" ] || [ "$factory_addr" = "0x0000000000000000000000000000000000000000" ]; then
    return 1
  fi

  if [ -z "$expected_registry" ] || [ "$expected_registry" = "null" ] || [ "$expected_registry" = "0x0000000000000000000000000000000000000000" ]; then
    return 1
  fi

  local registry_addr
  registry_addr="$(cast call "$factory_addr" "REGISTRY()" --rpc-url "$ANVIL_RPC_URL" 2>/dev/null | tr -d '\n')" || return 1
  # cast returns the ABI-encoded address (0x-padded to 32 bytes); extract the actual address.
  registry_addr="0x${registry_addr: -40}"

  if [ "$(echo "$registry_addr" | tr '[:upper:]' '[:lower:]')" != "$(echo "$expected_registry" | tr '[:upper:]' '[:lower:]')" ]; then
    return 1
  fi

  return 0
}

if [ "$FORCE_SEED" != "1" ] && [ -f "$ARTIFACT" ]; then
  NAVE_PIRATA_FACTORY="$(_json_string_field "$ARTIFACT" navePirataFactory)"
  NAVE_PIRATA_REGISTRY="$(_json_string_field "$ARTIFACT" navePirataRegistry)"
  if _factory_is_live "$NAVE_PIRATA_FACTORY" "$NAVE_PIRATA_REGISTRY"; then
    echo "Deployment artifact up to date: $ARTIFACT"
    exit 0
  fi
  echo "Deployment artifact is stale: factory at $NAVE_PIRATA_FACTORY is not deployed on the current chain."
  echo "Re-deploying Pacto governance contracts..."
fi

echo "Waiting for Anvil at $ANVIL_RPC_URL..."
for _ in $(seq 1 30); do
  if cast block-number --rpc-url "$ANVIL_RPC_URL" >/dev/null 2>&1; then
    echo "Anvil is ready."
    break
  fi
  sleep 1
done

cast block-number --rpc-url "$ANVIL_RPC_URL" >/dev/null

# Make sure the canonical Hats / Safe singletons exist on Anvil before the
# Pacto deploy scripts run, because they assume mainnet external addresses.
/usr/local/bin/ensure-external-contracts.sh

echo "Deploying Pacto governance contracts to Anvil (chain ID 31337)..."

forge script script/Deploy.sol \
  --rpc-url "$ANVIL_RPC_URL" \
  --broadcast \
  --private-key "$ANVIL_PRIVATE_KEY" \
  -vvvv

echo "Deployment complete. Artifacts written to $DEPLOYMENTS_DIR/"
if [ -f "$ARTIFACT" ]; then
  echo "Full-system artifact: $ARTIFACT"
  echo "registry: $(_json_string_field "$ARTIFACT" navePirataRegistry), hats: $(_json_string_field "$ARTIFACT" hats)"
fi

# Fix artifact ownership so the host user can read/write deployment files
# without relying on root privileges.  HOST_UID/HOST_GID are injected by make.
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ] && [ -d "$DEPLOYMENTS_DIR" ]; then
  echo "Fixing artifact ownership for host user $HOST_UID:$HOST_GID..."
  chown -R "$HOST_UID:$HOST_GID" "$DEPLOYMENTS_DIR" 2>/dev/null || true
fi
