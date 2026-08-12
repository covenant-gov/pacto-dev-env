#!/usr/bin/env bash
set -euo pipefail

# Reclaim exactly what one dev-world sandbox created: its port claim, its
# data directory, and its bot-side squad state. Safe to run twice -- every
# step tolerates its target already being absent, so a second run is a
# clean no-op. Never touches the shared stack, another sandbox, or the real
# OS data directory.
#
# Usage:
#   ./scripts/dev-world-reclaim.sh [--handle <path/to/sandbox-handle.json>]
#
# Without --handle, the handle path is derived the same way dev-world.sh
# derives it: PACTO_APP_DIR's current branch slug
# (scripts/dev-ports.mjs::slugForBranch) plus the persona.
#
# Env:
#   PACTO_APP_DIR          path to the pacto-app checkout (default: sibling ../pacto-app)
#   PACTO_DEV_WORLD_PERSONA  persona name (default: candidate, matching dev-world.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

err()  { echo -e "${RED}[dev-world-reclaim]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[dev-world-reclaim]${NC} $*"; }
ok()   { echo -e "${GREEN}[dev-world-reclaim]${NC} $*"; }

docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    (cd "$REPO_ROOT" && docker compose "$@")
  else
    (cd "$REPO_ROOT" && docker-compose "$@")
  fi
}

usage() {
  cat <<'EOF'
Usage: dev-world-reclaim.sh [--handle <path>]

Removes exactly what one dev-world sandbox created: releases its port-index
claim, deletes its sandbox data directory, and asks the bot daemon to drop
its squad/per-bot state. Idempotent -- safe to run against an already
reclaimed (or never-populated) sandbox.

  --handle <path>  Read this sandbox-handle.json instead of deriving one
                    from PACTO_APP_DIR + the current branch + the persona.

Env:
  PACTO_APP_DIR            pacto-app checkout (default: REPO_ROOT/../pacto-app)
  PACTO_DEV_WORLD_PERSONA  persona name (default: candidate, matching dev-world.sh)
EOF
}

HANDLE_PATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --handle)
      [ $# -ge 2 ] || { err "--handle requires a path argument"; exit 1; }
      HANDLE_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "unknown argument: $1"
      usage >&2
      exit 1
      ;;
  esac
done

for dep in jq node; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    err "required dependency '$dep' is not on PATH"
    exit 1
  fi
done

PERSONA="${PACTO_DEV_WORLD_PERSONA:-candidate}"
PACTO_APP_DIR="${PACTO_APP_DIR:-$REPO_ROOT/../pacto-app}"
if [ ! -d "$PACTO_APP_DIR" ]; then
  err "PACTO_APP_DIR does not exist: $PACTO_APP_DIR"
  exit 1
fi
PACTO_APP_DIR="$(cd "$PACTO_APP_DIR" && pwd)"

# The one canonical parent every sandbox root must live under. This is the
# boundary the safety guard below enforces -- see guard_sandbox_root().
SANDBOX_ROOT_PARENT="$PACTO_APP_DIR/test_sandbox"

if [ -z "$HANDLE_PATH" ]; then
  BRANCH="$(git -C "$PACTO_APP_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"
  DEV_PORTS_MJS="$PACTO_APP_DIR/scripts/dev-ports.mjs"
  if [ ! -f "$DEV_PORTS_MJS" ]; then
    err "cannot derive the handle path: $DEV_PORTS_MJS not found"
    exit 1
  fi
  SLUG="$(node -e "import('$DEV_PORTS_MJS').then(m => process.stdout.write(m.slugForBranch(process.argv[1])))" "$BRANCH")"
  HANDLE_PATH="$SANDBOX_ROOT_PARENT/$SLUG/$PERSONA/sandbox-handle.json"
fi

HANDLE_DIR="$(dirname -- "$HANDLE_PATH")"

# A missing handle *directory* means nothing was ever created here, or a
# prior run already reclaimed it -- a clean no-op, not an error. A missing
# handle *file* inside an existing directory means something is there that
# we cannot identify without guessing -- refuse rather than guess.
if [ ! -d "$HANDLE_DIR" ]; then
  ok "nothing to reclaim: $HANDLE_DIR does not exist (already reclaimed, or never populated)"
  exit 0
fi
if [ ! -f "$HANDLE_PATH" ]; then
  err "sandbox handle not found at $HANDLE_PATH -- refusing to guess what to reclaim"
  exit 1
fi

if ! HANDLE_JSON="$(jq -e '.' "$HANDLE_PATH" 2>&1)"; then
  err "sandbox handle at $HANDLE_PATH is not valid JSON: $HANDLE_JSON"
  exit 1
fi

SANDBOX_ROOT_RAW="$(jq -r '.sandboxRoot // empty' <<<"$HANDLE_JSON")"
PORT_INDEX="$(jq -r '.portIndex // empty' <<<"$HANDLE_JSON")"
PID="$(jq -r '.pid // empty' <<<"$HANDLE_JSON")"
DEV_PORT="$(jq -r '.ports.devServer // empty' <<<"$HANDLE_JSON")"
HMR_PORT="$(jq -r '.ports.hmr // empty' <<<"$HANDLE_JSON")"
BRIDGE_PORT="$(jq -r '.ports.mcpBridge // empty' <<<"$HANDLE_JSON")"
SQUAD_NAME="$(jq -r '.world.squadName // empty' <<<"$HANDLE_JSON")"
SQUAD_GROUP_ID="$(jq -r '.world.squadGroupId // empty' <<<"$HANDLE_JSON")"
SQUAD_BOT_ID="$(jq -r '.world.botId // empty' <<<"$HANDLE_JSON")"

if [ -z "$SANDBOX_ROOT_RAW" ]; then
  err "sandbox handle at $HANDLE_PATH has no sandboxRoot field"
  exit 1
fi

# --- Safety guard (U4): the single most important check in this script. ---
# Refuses to delete anything unless the resolved path is provably inside
# the canonical sandbox root. This must run, and must pass, before any
# other step touches the filesystem.

reject_dotdot() {
  case "$1" in
    ..|../*|*/../*|*/..) return 1 ;;
    *) return 0 ;;
  esac
}

# Portable equivalent of `realpath -m`: resolves symlinks and `..` for the
# longest existing prefix of $1 via `cd` + `pwd -P`, then appends whatever
# trailing components do not exist yet (there is nothing to resolve there).
canonicalize() {
  local target="${1%/}" remainder="" base resolved
  [ -z "$target" ] && target="/"
  while [ ! -e "$target" ] && [ "$target" != "/" ]; do
    base="$(basename -- "$target")"
    if [ -z "$remainder" ]; then remainder="$base"; else remainder="$base/$remainder"; fi
    target="$(dirname -- "$target")"
  done
  resolved="$(cd "$target" 2>/dev/null && pwd -P)" || return 1
  if [ -n "$remainder" ]; then
    printf '%s/%s\n' "$resolved" "$remainder"
  else
    printf '%s\n' "$resolved"
  fi
}

guard_sandbox_root() {
  local raw="$1" canonical_target canonical_parent

  if ! reject_dotdot "$raw"; then
    err "refusing to reclaim: sandboxRoot '$raw' contains a '..' path component"
    return 1
  fi
  case "$raw" in
    /*) : ;;
    *)
      err "refusing to reclaim: sandboxRoot '$raw' is not an absolute path"
      return 1
      ;;
  esac

  canonical_target="$(canonicalize "$raw")" || {
    err "refusing to reclaim: could not canonicalize sandboxRoot '$raw'"
    return 1
  }
  canonical_parent="$(canonicalize "$SANDBOX_ROOT_PARENT")" || {
    err "refusing to reclaim: could not canonicalize sandbox root parent '$SANDBOX_ROOT_PARENT'"
    return 1
  }

  case "$canonical_target" in
    "$canonical_parent"/*)
      printf '%s\n' "$canonical_target"
      return 0
      ;;
    *)
      err "refusing to reclaim: resolved sandboxRoot '$canonical_target' is not inside the sandbox root '$canonical_parent'"
      return 1
      ;;
  esac
}

CANONICAL_SANDBOX_ROOT="$(guard_sandbox_root "$SANDBOX_ROOT_RAW")"

# --- Step 1: release the port-index claim. ---
# dev-ports.mjs derives an index from the branch hash, takes an exclusive claim
# file for it, and confirms it by probing real listening sockets
# (resolvePortSet -> allPortsFree). Killing the recorded pid is still the whole
# job here: it frees the sockets immediately, which the probe re-verifies on
# every future resolution regardless of what any claim file says, so an index
# can never collide once its process is gone. The claim file itself is not
# deleted from this side -- it ages out on its own, needing both a dead pid and
# an expired grace window -- and a re-run of the same branch reclaims its own
# index straight away.
release_port_claim() {
  if [ -z "$PID" ]; then
    warn "handle has no live pid recorded; port index ${PORT_INDEX:-unknown} was likely already released"
    return 0
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    ok "pid $PID (port index ${PORT_INDEX:-unknown}) is not running; port claim already released"
    return 0
  fi

  warn "terminating pid $PID holding port index ${PORT_INDEX:-unknown} (devServer=${DEV_PORT:-?} hmr=${HMR_PORT:-?} mcpBridge=${BRIDGE_PORT:-?})"
  kill -TERM "$PID" 2>/dev/null || true
  local waited=0
  while kill -0 "$PID" 2>/dev/null && [ "$waited" -lt 10 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$PID" 2>/dev/null; then
    warn "pid $PID still alive after SIGTERM; sending SIGKILL"
    kill -KILL "$PID" 2>/dev/null || true
  fi
  ok "released port index ${PORT_INDEX:-unknown} (pid $PID terminated)"
}

# --- Step 2: delete the sandbox data directory. ---
# Guarded above: CANONICAL_SANDBOX_ROOT is proven to sit inside
# SANDBOX_ROOT_PARENT before this line ever runs.
delete_sandbox_dir() {
  if [ ! -e "$CANONICAL_SANDBOX_ROOT" ]; then
    ok "sandbox directory already absent: $CANONICAL_SANDBOX_ROOT"
    return 0
  fi
  rm -rf -- "$CANONICAL_SANDBOX_ROOT"
  ok "removed sandbox directory: $CANONICAL_SANDBOX_ROOT"
}

# --- Step 3: ask the bot side to drop this world's squad and per-bot state. ---
# `mls-group delete` is idempotent by contract: a group that is already gone is
# a success, so a second reclaim is a clean no-op. A failure here is reported
# but does not fail the reclaim -- the sandbox's own state is already gone by
# this point, and a stale bot-side group is recoverable while a half-reclaimed
# sandbox is not.
release_bot_side_state() {
  if [ -z "$SQUAD_NAME" ] && [ -z "$SQUAD_GROUP_ID" ]; then
    ok "handle has no world.squadName/world.squadGroupId; nothing to drop bot-side"
    return 0
  fi
  if [ -z "$SQUAD_GROUP_ID" ]; then
    warn "squad '${SQUAD_NAME}' has no recorded group id; cannot identify what to drop bot-side"
    return 0
  fi
  local bot_id="${SQUAD_BOT_ID:-bosun}"
  if docker_compose exec -T pacto-bot-api \
      pacto-bot-admin -c /etc/pacto/pacto-bot-api.toml -d /var/lib/pacto-bot-api \
      mls-group delete --bot "$bot_id" --group "$SQUAD_GROUP_ID" >/dev/null 2>&1; then
    ok "dropped squad '${SQUAD_NAME:-<unnamed>}' ($SQUAD_GROUP_ID) from bot '$bot_id'"
  else
    warn "could not drop squad '${SQUAD_NAME:-<unnamed>}' ($SQUAD_GROUP_ID) from bot '$bot_id'; the sandbox is reclaimed but that group may linger"
  fi
}

release_port_claim
delete_sandbox_dir
release_bot_side_state

ok "reclaim complete for $HANDLE_PATH"
