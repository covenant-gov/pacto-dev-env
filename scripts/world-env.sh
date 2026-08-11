#!/usr/bin/env bash
set -euo pipefail

# Emits `export` lines for the local-chain contract addresses recorded by the
# seeding scripts (data/deployments/<chainId>/full-system.json), so a dev
# build can override its compiled address book for the local network only.
#
# Output is meant for `eval "$(./scripts/world-env.sh)"` or `source`: only
# export lines land on stdout, every human-readable note goes to stderr.
#
# Usage:
#   ./scripts/world-env.sh [--chain-id <id>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

err() { echo -e "${RED}[world-env]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[world-env]${NC} $*" >&2; }

CHAIN_ID="31337"

while [ $# -gt 0 ]; do
  case "$1" in
    --chain-id)
      CHAIN_ID="${2:?--chain-id requires a value}"
      shift 2
      ;;
    --chain-id=*)
      CHAIN_ID="${1#--chain-id=}"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--chain-id <id>]" >&2
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  err "jq is required but not found on PATH."
  exit 1
fi

ARTIFACT="$REPO_ROOT/data/deployments/$CHAIN_ID/full-system.json"

if [ ! -f "$ARTIFACT" ]; then
  err "Deployment artifact not found: $ARTIFACT"
  err "Run 'make seed' (chain id $CHAIN_ID) to deploy contracts and generate it."
  exit 1
fi

if ! jq empty "$ARTIFACT" 2>/dev/null; then
  err "Deployment artifact is not valid JSON: $ARTIFACT"
  exit 1
fi

# Artifact JSON key -> env var, per the fixed local-chain override mapping.
# Every var carries the _LOCAL suffix so it only overrides the "local"
# network entry in the compiled address book, never sepolia or mainnet.
MAPPINGS="navePirataFactory:PACTO_NAVE_PIRATA_FACTORY_LOCAL
masterQuartermaster:PACTO_NAV_MASTER_QUARTERMASTER_LOCAL
masterMutinyModule:PACTO_NAV_MASTER_MUTINY_LOCAL
masterTreasuryAuthority:PACTO_NAV_MASTER_TREASURY_AUTHORITY_LOCAL
masterSquadAdminImpl:PACTO_NAV_MASTER_SQUAD_ADMIN_LOCAL
masterSquadAdminExtImpl:PACTO_NAV_MASTER_SQUAD_ADMIN_EXT_LOCAL
navePirataRegistry:PACTO_NAVE_PIRATA_REGISTRY_LOCAL
hats:PACTO_HATS_LOCAL
roleHatClonesFactory:PACTO_ROLE_HAT_CLONES_FACTORY_LOCAL
roleHatUpgrader:PACTO_ROLE_HAT_UPGRADER_LOCAL
safeProxyFactory:PACTO_SAFE_PROXY_FACTORY_LOCAL
safeSingleton:PACTO_SAFE_SINGLETON_LOCAL"

printf 'export PACTO_LOCAL_CHAIN_ID=%q\n' "$CHAIN_ID"

exported=0
skipped=0
while IFS=: read -r key var; do
  [ -z "$key" ] && continue

  value="$(jq -r --arg k "$key" '.[$k] // empty' "$ARTIFACT")"

  if [ -z "$value" ]; then
    continue
  fi

  if ! [[ "$value" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    warn "Skipping '$key': not a valid address ($value)"
    skipped=$((skipped + 1))
    continue
  fi

  printf 'export %s=%q\n' "$var" "$value"
  exported=$((exported + 1))
done <<< "$MAPPINGS"

warn "Exported $exported address override(s) from $ARTIFACT (skipped $skipped)."
