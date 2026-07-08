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

if [ "$FORCE_SEED" != "1" ] && [ -f "$ARTIFACT" ]; then
  echo "Deployment artifact already exists: $ARTIFACT"
  echo "Run with FORCE_SEED=1 to re-deploy, or run 'make reset' to clear state."
  exit 0
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
  jq -r '"registry: \(.navePirataRegistry), hats: \(.hats)"' "$ARTIFACT" 2>/dev/null || true
fi
