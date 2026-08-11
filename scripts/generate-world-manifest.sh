#!/usr/bin/env bash
set -euo pipefail

# Derive a dev world's cast from its committed recipe and write the public
# manifest plus its gitignored secret sidecar.
#
# Reads worlds/${WORLD:-default}.world.json, derives every persona in its
# `cast` via scripts/derive-identity.py, and writes:
#   data/world/${WORLD}/world-state.json    (0644, matches schemas/world-state.schema.json)
#   data/world/${WORLD}/world-secrets.json  (0600, matches schemas/secrets-sidecar.schema.json)
#
# Deterministic: the same world file always produces byte-identical output.
# Safe to re-run; each run overwrites both files unconditionally.
#
# Usage:
#   WORLD=default ./scripts/generate-world-manifest.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

err() { echo -e "${RED}[generate-world-manifest]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[generate-world-manifest]${NC} $*" >&2; }
ok() { echo -e "${GREEN}[generate-world-manifest]${NC} $*"; }

WORLD="${WORLD:-default}"
WORLD_FILE="$REPO_ROOT/worlds/$WORLD.world.json"

if [ ! -f "$WORLD_FILE" ]; then
  err "World file not found: $WORLD_FILE"
  exit 1
fi

if ! command -v cast >/dev/null 2>&1; then
  err "cast (foundry) is required but not found in PATH"
  exit 1
fi

ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT

if ! SUMMARY="$(REPO_ROOT="$REPO_ROOT" WORLD="$WORLD" WORLD_FILE="$WORLD_FILE" python3 - <<'PYEOF' 2>"$ERR_FILE"
import importlib.util
import json
import os
import sys
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"])
world_name = os.environ["WORLD"]
world_file = Path(os.environ["WORLD_FILE"])


def die(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def require(obj, key, ctx):
    if not isinstance(obj, dict) or key not in obj:
        die(f"{ctx} is missing required field '{key}'")
    return obj[key]


try:
    raw = world_file.read_text()
except OSError as exc:
    die(f"could not read {world_file}: {exc}")

try:
    world = json.loads(raw)
except json.JSONDecodeError as exc:
    die(f"{world_file} is not valid JSON: {exc}")

recipe = require(world, "recipe", str(world_file))
root_seed = require(world, "devRootSeed", str(world_file))
world_block = require(world, "world", str(world_file))
cast = require(world, "cast", str(world_file))

if not isinstance(cast, list) or len(cast) == 0:
    die(f"{world_file}: 'cast' must be a non-empty array")

name = require(world_block, "name", "world.world")
relay_endpoint = require(world_block, "relayEndpoint", "world.world")
chain = require(world_block, "chain", "world.world")
chain_endpoint = require(chain, "endpoint", "world.world.chain")
chain_id = require(chain, "chainId", "world.world.chain")
deployment_artifacts = world_block.get("deploymentArtifacts")

spec = importlib.util.spec_from_file_location(
    "derive_identity", repo_root / "scripts" / "derive-identity.py"
)
derive_identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(derive_identity)

personas = []
identities = []
for i, entry in enumerate(cast):
    ctx = f"cast[{i}]"
    persona_name = require(entry, "name", ctx)
    role = require(entry, "role", ctx)
    bot_id = require(entry, "botId", ctx)
    squad_role = require(entry, "squadRole", ctx)

    try:
        identity = derive_identity.derive(root_seed, recipe, persona_name)
    except Exception as exc:
        die(f"failed to derive identity for '{persona_name}': {exc}")

    personas.append({
        "name": persona_name,
        "role": role,
        "npub": identity["npub"],
        "ethAddress": identity["ethAddress"],
        "botId": bot_id,
        "squadRole": squad_role,
        "derivation": {"recipe": recipe, "label": persona_name},
        "sandboxOnly": True,
    })
    identities.append({
        "name": persona_name,
        "npub": identity["npub"],
        "nsec": identity["nsec"],
        "ethAddress": identity["ethAddress"],
        "ethPrivateKey": identity["ethPrivateKey"],
        "sandboxOnly": True,
    })

world_out = {
    "name": name,
    "relayEndpoint": relay_endpoint,
    "chain": {"endpoint": chain_endpoint, "chainId": chain_id},
}
if deployment_artifacts is not None:
    world_out["deploymentArtifacts"] = deployment_artifacts

manifest = {
    "manifestVersion": 1,
    "recipe": {"id": recipe, "public": True},
    "world": world_out,
    "personas": personas,
}

sidecar = {
    "manifestVersion": 1,
    "recipe": recipe,
    "identities": identities,
}

out_dir = repo_root / "data" / "world" / world_name
out_dir.mkdir(parents=True, exist_ok=True)

manifest_path = out_dir / "world-state.json"
sidecar_path = out_dir / "world-secrets.json"

manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
manifest_path.chmod(0o644)

# Open with restrictive mode from creation so the secret material is never
# briefly world-readable between write and chmod.
fd = os.open(str(sidecar_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(json.dumps(sidecar, indent=2) + "\n")
os.chmod(str(sidecar_path), 0o600)

print(f"World: {world_name}")
print(f"Personas: {len(personas)}")
print(f"Manifest: {manifest_path}")
print(f"Sidecar: {sidecar_path}")
PYEOF
)"; then
  err "$(cat "$ERR_FILE")"
  exit 1
fi

while IFS= read -r line; do
  ok "$line"
done <<< "$SUMMARY"
