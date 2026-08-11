#!/usr/bin/env bash
set -euo pipefail

# One command: stack running -> this worktree has a populated, joined squad.
#
# Walks eight named gates in order, printing "[gate:<name>] passed" as each
# clears and "[gate:<name>] FAILED: <what was observed instead>" (exit 1) at
# the first one that does not. The gates exist to turn a silent hang (e.g. a
# keypackage the bot can never resolve) into a named failure instead of a
# timeout with no diagnosis.
#
# Gates, in order: docker, stack-ready, seed, app-launch,
# keypackage-resolvable, squad-invited, welcome-accepted, history-visible.
#
# Usage:
#   ./scripts/dev-world.sh
#   PACTO_DEV_WORLD_STOP_AFTER=seed ./scripts/dev-world.sh   # stop early
#
# Optional environment variables:
#   WORLD                        - world recipe to use (default: default);
#                                   see `make world-manifest`.
#   PACTO_APP_DIR                - path to the pacto-app worktree that this
#                                   sandbox belongs to (default: ../pacto-app,
#                                   mirroring PACTO_GOV_DIR).
#   PACTO_DEV_WORLD_PERSONA      - app-owned manifest persona to log the
#                                   sandbox in as (default: candidate). Must
#                                   name a persona whose manifest "owner" is
#                                   "app"; a bot-owned persona (owner "bot",
#                                   e.g. bosun/captain) is refused at the
#                                   app-launch gate, naming the persona, its
#                                   owner, and the app-owned personas
#                                   available, so an app sandbox can never
#                                   share an nsec with a live bot identity.
#   BOT_ID                       - admin bot that owns the squad (default:
#                                   bosun), same variable invite-squad.sh reads.
#   PACTO_DEV_WORLD_STOP_AFTER   - gate name to stop after (for testing
#                                   without booting the app, or resuming a
#                                   debugging run).
#   PACTO_DEV_WORLD_APP_TIMEOUT  - seconds to wait for app readiness at the
#                                   app-launch gate (default: 180).
#
# Idempotence: re-running against an already-populated sandbox re-enters at
# the first unsatisfied gate rather than duplicating a squad. app-launch
# checks the sandbox handle's recorded pid; squad-invited and
# keypackage-resolvable check a local progress marker
# (<sandbox root>/dev-world-state.json) cross-referenced against the shared
# deployment artifact so a wiped bot-api data volume is not trusted as still
# live; welcome-accepted and history-visible always re-check the sandbox's
# own state directly, so a stale marker still produces a real (if slower)
# retry instead of a false pass.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[dev-world]${NC} $*"; }
warn() { echo -e "${YELLOW}[dev-world]${NC} $*" >&2; }
err()  { echo -e "${RED}[dev-world]${NC} $*" >&2; }

gate_pass() { ok "[gate:$1] passed"; }
gate_fail() { err "[gate:$1] FAILED: $2"; exit 1; }

maybe_stop_after() {
  if [ "${PACTO_DEV_WORLD_STOP_AFTER:-}" = "$1" ]; then
    ok "PACTO_DEV_WORLD_STOP_AFTER=$1 reached; stopping before the next gate."
    exit 0
  fi
}

WORLD="${WORLD:-default}"
PACTO_APP_DIR="${PACTO_APP_DIR:-$REPO_ROOT/../pacto-app}"
SANDBOX_PERSONA="${PACTO_DEV_WORLD_PERSONA:-candidate}"
INVITER_BOT_ID="${BOT_ID:-bosun}"

docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    (cd "$REPO_ROOT" && docker compose "$@")
  else
    (cd "$REPO_ROOT" && docker-compose "$@")
  fi
}

# ---------------------------------------------------------------------------
# Gate 1: docker
# ---------------------------------------------------------------------------

gate_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    gate_fail docker \
      "docker is not installed or not in PATH. dev-world needs the Docker-backed stack (anvil, nostr-relay, pacto-bot-api). Without Docker, use the plain dev path in pacto-app instead: cd $PACTO_APP_DIR && make dev"
  fi
  if ! docker info >/dev/null 2>&1; then
    gate_fail docker \
      "docker is installed but not running (docker info failed). Start Docker, or use the plain dev path in pacto-app instead: cd $PACTO_APP_DIR && make dev"
  fi
  gate_pass docker
}

# ---------------------------------------------------------------------------
# Gate 2: stack-ready
# ---------------------------------------------------------------------------

# Reuses scripts/verify-stack.sh as a subprocess rather than re-probing the
# services here. Its own pass/warn/fail lines are captured so a bot-api-only
# failure (daemon not answering) can be told apart from the stack simply
# being down, per the plan's separate failure modes -- both are reported
# under the single fixed gate name "stack-ready" the naming contract defines.
gate_stack_ready() {
  local output status=0
  output="$("$SCRIPT_DIR/verify-stack.sh" 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    gate_pass stack-ready
    return
  fi

  local bot_lines core_lines
  bot_lines="$(printf '%s\n' "$output" | grep '✗' | grep 'pacto-bot-api' || true)"
  core_lines="$(printf '%s\n' "$output" | grep '✗' | grep -v 'pacto-bot-api' || true)"

  if [ -z "$core_lines" ] && [ -n "$bot_lines" ]; then
    gate_fail stack-ready \
      "stack is up but the pacto-bot-api daemon is not answering: $(printf '%s\n' "$bot_lines" | sed -e 's/^[[:space:]]*//' | tr '\n' ';')"
  fi
  gate_fail stack-ready \
    "stack is not up: $(printf '%s\n' "$output" | grep '✗' | sed -e 's/^[[:space:]]*//' | tr '\n' ';')"
}

# ---------------------------------------------------------------------------
# Gate 3: seed
# ---------------------------------------------------------------------------

# `make seed` runs the one-shot compose service that mounts and executes
# scripts/seed-anvil.sh; that script alone owns the "is the artifact
# deployed and live" definition (artifact presence plus an on-chain
# liveness check), so nothing here re-derives it.
gate_seed() {
  local output status=0
  output="$(cd "$REPO_ROOT" && make seed 2>&1)" || status=$?
  if [ "$status" -ne 0 ]; then
    gate_fail seed "'make seed' failed: $(printf '%s\n' "$output" | tail -5 | tr '\n' ' ')"
  fi
  gate_pass seed
}

# ---------------------------------------------------------------------------
# World manifest / sandbox root resolution (shared prerequisites, not gates
# of their own -- failures here are attributed to app-launch, the first gate
# that needs them).
# ---------------------------------------------------------------------------

resolve_world_identity() {
  local manifest="$REPO_ROOT/data/world/$WORLD/world-state.json"
  local sidecar="$REPO_ROOT/data/world/$WORLD/world-secrets.json"

  command -v jq >/dev/null 2>&1 || gate_fail app-launch "jq is required to read the world manifest but was not found in PATH"

  if [ ! -f "$manifest" ] || [ ! -f "$sidecar" ]; then
    gate_fail app-launch "world manifest not found for WORLD=$WORLD (expected $manifest and $sidecar); run 'make world-manifest' first"
  fi

  local persona_owner
  persona_owner="$(jq -r --arg n "$SANDBOX_PERSONA" '.personas[] | select(.name == $n) | .owner // empty' "$manifest")"

  if [ -z "$persona_owner" ]; then
    local all_personas
    all_personas="$(jq -r '[.personas[].name] | join(", ")' "$manifest")"
    gate_fail app-launch "persona '$SANDBOX_PERSONA' not found in the world manifest for WORLD=$WORLD; available personas: ${all_personas:-none} (run 'make world-manifest' first if the list is empty)"
  fi

  if [ "$persona_owner" != "app" ]; then
    local app_personas
    app_personas="$(jq -r '[.personas[] | select(.owner == "app") | .name] | join(", ")' "$manifest")"
    gate_fail app-launch "persona '$SANDBOX_PERSONA' has owner '$persona_owner', not 'app'; a pacto-app sandbox may only log in as an app-owned persona, or it would share an nsec with a live pacto-bot-api identity (an MLS-state-corruption hazard). App-owned personas available: ${app_personas:-none}"
  fi

  IDENTITY_NPUB="$(jq -r --arg n "$SANDBOX_PERSONA" '.personas[] | select(.name == $n) | .npub // empty' "$manifest")"
  RELAY_ENDPOINT="$(jq -r '.world.relayEndpoint // empty' "$manifest")"
  IDENTITY_MNEMONIC="$(jq -r --arg n "$SANDBOX_PERSONA" '.identities[] | select(.name == $n) | .mnemonic // empty' "$sidecar")"

  if [ -z "$IDENTITY_NPUB" ] || [ -z "$IDENTITY_MNEMONIC" ]; then
    gate_fail app-launch "persona '$SANDBOX_PERSONA' not found in the world manifest/sidecar for WORLD=$WORLD (checked $manifest, $sidecar)"
  fi
  if [ -z "$RELAY_ENDPOINT" ]; then
    gate_fail app-launch "world manifest $manifest has no world.relayEndpoint"
  fi
}

resolve_sandbox_root() {
  [ -d "$PACTO_APP_DIR" ] || gate_fail app-launch "PACTO_APP_DIR does not exist: $PACTO_APP_DIR (set PACTO_APP_DIR to the pacto-app worktree)"
  command -v node >/dev/null 2>&1 || gate_fail app-launch "node is required to derive the sandbox root (scripts/dev-ports.mjs) and to drive scripts/app-bridge.mjs, but was not found in PATH"

  local branch
  branch="$(git -C "$PACTO_APP_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"
  BRANCH_SLUG="$(cd "$PACTO_APP_DIR" && node -e "import('./scripts/dev-ports.mjs').then(m => process.stdout.write(m.slugForBranch(process.argv[1])))" "$branch")"
  [ -n "$BRANCH_SLUG" ] || gate_fail app-launch "could not derive a branch slug from scripts/dev-ports.mjs for branch '$branch'"

  SANDBOX_ROOT="$PACTO_APP_DIR/test_sandbox/$BRANCH_SLUG/$SANDBOX_PERSONA"
  HANDLE_FILE="$SANDBOX_ROOT/sandbox-handle.json"
  STATE_FILE="$SANDBOX_ROOT/dev-world-state.json"
  SQUAD_NAME="dev-world-${BRANCH_SLUG}-${SANDBOX_PERSONA}"
}

# Tiny local progress marker, private to dev-world.sh. Distinct from the
# sandbox handle's `world` block, which is only merged in after every gate
# passes (see merge_world_block) and so cannot itself serve as a mid-way
# resume marker.
state_get() {
  [ -f "$STATE_FILE" ] || return 0
  jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null
}

state_set() {
  local tmp
  tmp="$(mktemp)"
  if [ -f "$STATE_FILE" ]; then
    jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$STATE_FILE" >"$tmp"
  else
    jq -n --arg k "$1" --arg v "$2" '{($k): $v}' >"$tmp"
  fi
  mv "$tmp" "$STATE_FILE"
}

# A persisted squadGroupId is only trusted while the shared per-bot
# deployment artifact this repo's own scripts write is still present. A
# `make reset` deletes ./data (including that artifact) but cannot touch
# dev-world's own state file, which lives under the pacto-app worktree --
# so file absence is the cheapest available signal that the referenced
# squad was wiped out from under a stale marker. The bot's own MLS store is
# encrypted at rest and not independently queryable, so this is the
# liveness check available without adding new tooling.
squad_marker_valid() {
  local existing
  existing="$(state_get squadGroupId)"
  if [ -n "$existing" ] && [ -f "$REPO_ROOT/data/deployments/31337/group-$INVITER_BOT_ID.json" ]; then
    EXISTING_GROUP_ID="$existing"
    return 0
  fi
  EXISTING_GROUP_ID=""
  return 1
}

# ---------------------------------------------------------------------------
# Gate 4: app-launch
# ---------------------------------------------------------------------------

# A live pid is not enough: an app left over from an earlier run may never have
# logged in, or may hold a different identity than the manifest now specifies.
# Such a sandbox publishes no keypackage, so reusing it silently poisons every
# gate after this one. Require the handle's npub to match before reusing.
app_already_running() {
  local pid handle_npub
  [ -f "$HANDLE_FILE" ] || return 1
  pid="$(jq -r '.pid // empty' "$HANDLE_FILE" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  handle_npub="$(jq -r '.npub // empty' "$HANDLE_FILE" 2>/dev/null)"
  [ "$handle_npub" = "$IDENTITY_NPUB" ]
}

stop_stale_app() {
  local pid
  [ -f "$HANDLE_FILE" ] || return 0
  pid="$(jq -r '.pid // empty' "$HANDLE_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  warn "a sandbox app is running for $SANDBOX_ROOT (pid $pid) but is not authenticated as $IDENTITY_NPUB; restarting it"
  kill "$pid" 2>/dev/null || true
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 10 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  kill -9 "$pid" 2>/dev/null || true
}

# Upstream bug pacto-app-384.73: on a first boot the app starts its
# account-wide event stream before any relay is in the pool, fails with "no
# relays specified", and never re-establishes it. The app then looks healthy --
# relay connected, "Sync Complete" printed -- while ingesting nothing, so the
# welcome never arrives and every later gate starves. A restart fixes it,
# because by then the relay is persisted. Detect that exact line and relaunch
# once rather than making a developer run this command twice.
DEAD_STREAM_MARKER='Account-wide relay event stream failed: no relays specified'

launch_app() {
  local log_file="$1"
  mkdir -p "$SANDBOX_ROOT"
  ok "launching pacto-app sandbox in the background (persona '$SANDBOX_PERSONA', log: $log_file)..."
  (
    cd "$PACTO_APP_DIR" && \
    PACTO_TRUSTED_RELAYS="$RELAY_ENDPOINT" \
    PACTO_DEV_LOGIN_MNEMONIC="$IDENTITY_MNEMONIC" \
    PACTO_DEV_IDENTITY_SANDBOX_ONLY=1 \
    PERSONA="$SANDBOX_PERSONA" \
    make dev-sandbox
  ) >"$log_file" 2>&1 &
  disown
}

wait_for_app() {
  local log_file="$1" timeout="${PACTO_DEV_WORLD_APP_TIMEOUT:-180}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if [ -f "$HANDLE_FILE" ] && grep -q "Sync Complete" "$log_file" 2>/dev/null; then
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

gate_app_launch() {
  if app_already_running; then
    ok "app already running for $SANDBOX_ROOT (pid $(jq -r '.pid' "$HANDLE_FILE")); reusing it"
    gate_pass app-launch
    return
  fi
  stop_stale_app

  local log_file="$SANDBOX_ROOT/dev-world-app.log"
  local attempt
  for attempt in 1 2; do
    launch_app "$log_file"
    if ! wait_for_app "$log_file"; then
      gate_fail app-launch \
        "pacto-app sandbox did not reach readiness within ${PACTO_DEV_WORLD_APP_TIMEOUT:-180}s (waiting for $HANDLE_FILE and a 'Sync Complete' line in $log_file); see $log_file"
    fi
    if ! grep -q "$DEAD_STREAM_MARKER" "$log_file" 2>/dev/null; then
      gate_pass app-launch
      return
    fi
    if [ "$attempt" -eq 1 ]; then
      warn "the sandbox came up with a dead event stream (pacto-app-384.73); restarting it once"
      stop_stale_app
    fi
  done
  gate_fail app-launch \
    "pacto-app sandbox still has a dead event stream after a restart (pacto-app-384.73): '$DEAD_STREAM_MARKER' in $log_file. It would ingest nothing, so later gates would starve."
}

# ---------------------------------------------------------------------------
# Gate 5: keypackage-resolvable
# ---------------------------------------------------------------------------

# Same primitive scripts/create-mls-group.sh polls with (query_key_package.py
# over the relay's websocket, run once per relay via a throwaway container);
# invoked directly here rather than through create-mls-group.sh, which would
# also create a group as a side effect that belongs to gate 6, not this one.
key_package_found() {
  local npub="$1" timeout="${2:-5}" output
  output="$(docker run --rm --network pacto \
    -e RELAY_URL="ws://nostr-relay:8080" -e AUTHOR="$npub" -e TIMEOUT="$timeout" \
    -v "$SCRIPT_DIR/query_key_package.py:/query.py:ro" \
    python:3-slim \
    sh -c "pip install -q --root-user-action=ignore websockets && python /query.py" 2>/dev/null)"
  python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("found", False) else 1)' <<<"$output" 2>/dev/null
}

gate_keypackage_resolvable() {
  if squad_marker_valid; then
    ok "squad already invited ($EXISTING_GROUP_ID); that KeyPackage was already consumed by the invite, skipping a fresh check"
    gate_pass keypackage-resolvable
    return
  fi

  local attempt
  for attempt in $(seq 1 8); do
    if key_package_found "$IDENTITY_NPUB" 5; then
      gate_pass keypackage-resolvable
      return
    fi
    warn "KeyPackage for $IDENTITY_NPUB not yet resolvable by the bot (attempt $attempt/8); retrying..."
    sleep 3
  done
  gate_fail keypackage-resolvable \
    "no resolvable KeyPackage for identity $IDENTITY_NPUB after 8 attempts (~24s). Publication and bot-side indexing are different events; the bot could not resolve one."
}

# ---------------------------------------------------------------------------
# Gate 6: squad-invited
# ---------------------------------------------------------------------------

gate_squad_invited() {
  if squad_marker_valid; then
    ok "squad '$SQUAD_NAME' already invited ($EXISTING_GROUP_ID)"
    SQUAD_GROUP_ID="$EXISTING_GROUP_ID"
    gate_pass squad-invited
    return
  fi

  ok "creating squad '$SQUAD_NAME' owned by '$INVITER_BOT_ID' and inviting '$IDENTITY_NPUB'..."
  local group_id
  if ! group_id="$(BOT_ID="$INVITER_BOT_ID" SQUAD_NAME="$SQUAD_NAME" RECIPIENT_NPUB="$IDENTITY_NPUB" "$SCRIPT_DIR/invite-squad.sh" | tail -1)"; then
    gate_fail squad-invited "invite-squad.sh failed creating/inviting squad '$SQUAD_NAME' for bot '$INVITER_BOT_ID' -> '$IDENTITY_NPUB'"
  fi
  if [ -z "$group_id" ]; then
    gate_fail squad-invited "invite-squad.sh produced no group id for squad '$SQUAD_NAME'"
  fi

  state_set squadName "$SQUAD_NAME"
  state_set squadGroupId "$group_id"
  SQUAD_GROUP_ID="$group_id"
  gate_pass squad-invited
}

# ---------------------------------------------------------------------------
# Gate 7: welcome-accepted
# ---------------------------------------------------------------------------

group_in_app_db() {
  local db="$1" group_id="$2" count
  [ -f "$db" ] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 1
  count="$(sqlite3 "$db" "SELECT count(*) FROM mls_groups WHERE group_id = '$group_id';" 2>/dev/null)" || return 1
  [ "${count:-0}" -gt 0 ]
}

read_bridge_port() {
  jq -r '.ports.mcpBridge // empty' "$HANDLE_FILE" 2>/dev/null
}

gate_welcome_accepted() {
  local db="$SANDBOX_ROOT/data/$IDENTITY_NPUB/pacto.db"

  if group_in_app_db "$db" "$SQUAD_GROUP_ID"; then
    gate_pass welcome-accepted
    return
  fi

  if [ ! -f "$SCRIPT_DIR/app-bridge.mjs" ]; then
    gate_fail welcome-accepted \
      "scripts/app-bridge.mjs not found; cannot drive the Accept click for squad '$SQUAD_NAME' ($SQUAD_GROUP_ID)"
  fi

  local bridge_port
  bridge_port="$(read_bridge_port)"
  if [ -z "$bridge_port" ]; then
    gate_fail welcome-accepted "no mcpBridge port recorded in $HANDLE_FILE"
  fi

  # There is deliberately no headless auto-accept command in the app:
  # consent is the point of an invite. This drives the one real Accept
  # click through the running sandbox's own MLS commands instead of
  # bypassing it.
  local eval_js accept_output
  eval_js="(async () => { const invoke = window.__TAURI__.core.invoke; const welcomes = await invoke('list_pending_mls_welcomes'); const target = welcomes.find(w => w.nostr_group_id === '$SQUAD_GROUP_ID' || w.group_name === '$SQUAD_NAME'); if (!target) { throw new Error('no pending welcome for squad $SQUAD_NAME ($SQUAD_GROUP_ID)'); } const accepted = await invoke('accept_mls_welcome', { welcomeEventIdHex: target.id }); return { accepted, groupId: target.nostr_group_id }; })()"

  # Delivery is asynchronous: the gift wrap still has to reach the sandbox and
  # be unwrapped before there is anything to accept, so a single attempt races
  # the relay. Retry the click until the welcome lands.
  local attempt accept_output="" accepted=0
  for attempt in $(seq 1 15); do
    if accept_output="$(node "$SCRIPT_DIR/app-bridge.mjs" --port "$bridge_port" --eval "$eval_js" 2>&1)"; then
      accepted=1
      break
    fi
    sleep 2
  done
  if [ "$accepted" -ne 1 ]; then
    gate_fail welcome-accepted \
      "app-bridge.mjs could not drive the Accept click for squad '$SQUAD_NAME' after 15 attempts (~30s): $accept_output"
  fi

  for attempt in $(seq 1 10); do
    if group_in_app_db "$db" "$SQUAD_GROUP_ID"; then
      gate_pass welcome-accepted
      return
    fi
    sleep 2
  done
  gate_fail welcome-accepted \
    "Accept was driven ($accept_output) but squad '$SQUAD_NAME' ($SQUAD_GROUP_ID) never appeared in $db"
}

# ---------------------------------------------------------------------------
# Gate 8: history-visible
# ---------------------------------------------------------------------------

# A bare bot secret cannot reach `agent.send_group_message`: it is
# handler-callable, so the daemon answers a raw POST with 401 "handler identity
# required". Go through the admin CLI verb, which registers an ephemeral
# handler carrying exactly the `SendGroupMessages` capability.
bot_admin() {
  docker_compose exec -T pacto-bot-api \
    pacto-bot-admin -c /etc/pacto/pacto-bot-api.toml -d /var/lib/pacto-bot-api "$@"
}

send_group_message() {
  local bot_id="$1" group_id="$2" content="$3"
  bot_admin mls-group send --bot "$bot_id" --group "$group_id" --content "$content" >/dev/null 2>&1
}

# The inviter bot's own npub, read from the daemon's config. A DM chat is keyed
# by the counterparty, not by the sandbox itself, so this is what gate 8 has to
# ask for. The bot roster is not generated from the world manifest yet, so the
# manifest's derived bosun npub is not this value.
inviter_bot_npub() {
  docker_compose exec -T pacto-bot-api sh -c \
    "grep -A5 'id = \"$INVITER_BOT_ID\"' /etc/pacto/pacto-bot-api.toml | grep -m1 npub" 2>/dev/null |
    sed -E 's/.*"(npub1[a-z0-9]+)".*/\1/' | tr -d '[:space:]'
}

# Gates on the DM backlog actually being readable by the sandbox. `offset` is
# required by the command, and omitting it makes every call error rather than
# return nothing -- which reads as "not delivered yet" and burns the whole retry
# budget on a malformed request.
#
# Squad history is deliberately NOT gated on retrievability: pacto-app-384.75
# means a bot's group message can never render in the app. The bot writes every
# in-MLS rumor as kind 1, and pacto-app renders only kinds 14, 15 and 30078, so
# the message is stored and ignored. Gating on it here would block the whole
# world on a defect that lives in neither script.
dm_backlog_retrievable() {
  local bridge_port dm_chat_id js out
  bridge_port="$(read_bridge_port)"
  [ -n "$bridge_port" ] || return 1
  [ -f "$SCRIPT_DIR/app-bridge.mjs" ] || return 1
  dm_chat_id="$(inviter_bot_npub)"
  [ -n "$dm_chat_id" ] || return 1
  js="(async () => { const invoke = window.__TAURI__.core.invoke; const dm = await invoke('get_chat_messages_paginated', { chatId: '$dm_chat_id', limit: 5, offset: 0 }); return { dm: dm.length }; })()"
  out="$(node "$SCRIPT_DIR/app-bridge.mjs" --port "$bridge_port" --eval "$js" 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -e '(.dm // 0) > 0' >/dev/null 2>&1
}

gate_history_visible() {
  if [ "$(state_get historySent)" = "true" ] && dm_backlog_retrievable; then
    gate_pass history-visible
    return
  fi

  # Both are generated only now, after the welcome was accepted: forward secrecy
  # hides pre-join messages from a new member, so seeding either earlier would
  # leave it permanently invisible to this sandbox.
  local dm_content="Dev-world DM backlog seed for ${SQUAD_NAME}."
  local squad_content="Dev-world squad history seed for ${SQUAD_NAME}."

  if ! bot_admin send-test-dm "$INVITER_BOT_ID" "$IDENTITY_NPUB" "$dm_content" >/dev/null; then
    gate_fail history-visible "could not send the DM backlog seed from '$INVITER_BOT_ID' to '$IDENTITY_NPUB'"
  fi

  if ! send_group_message "$INVITER_BOT_ID" "$SQUAD_GROUP_ID" "$squad_content"; then
    gate_fail history-visible "could not send the squad history seed message to group '$SQUAD_GROUP_ID' as bot '$INVITER_BOT_ID'"
  fi

  state_set historySent true

  local attempt
  for attempt in $(seq 1 10); do
    if dm_backlog_retrievable; then
      warn "squad history was accepted by the bot but cannot render in the app yet (pacto-app-384.75); only the DM backlog is gated"
      gate_pass history-visible
      return
    fi
    sleep 3
  done
  gate_fail history-visible \
    "the DM backlog was sent but is not retrievable by the sandbox after 10 attempts (~30s); expected a DM chat keyed by '$(inviter_bot_npub)'"
}

# ---------------------------------------------------------------------------
# Populated-world handle + summary
# ---------------------------------------------------------------------------

merge_world_block() {
  local tmp
  tmp="$(mktemp)"
  jq --arg squadName "$SQUAD_NAME" \
     --arg squadGroupId "$SQUAD_GROUP_ID" \
     --arg botId "$INVITER_BOT_ID" \
     --arg populatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.world = {recipe: "pacto-dev-world/v1", squadName: $squadName, squadGroupId: $squadGroupId, botId: $botId, populatedAt: $populatedAt}' \
     "$HANDLE_FILE" >"$tmp" && mv "$tmp" "$HANDLE_FILE"
}

print_summary() {
  local app_pid
  app_pid="$(jq -r '.pid // "unknown"' "$HANDLE_FILE" 2>/dev/null)"
  echo
  ok "world populated:"
  ok "  squad name    : $SQUAD_NAME"
  ok "  group id      : $SQUAD_GROUP_ID"
  ok "  sandbox root  : $SANDBOX_ROOT"
  ok "  mcp bridge    : $(read_bridge_port)"
  ok "  app pid       : $app_pid"
}

main() {
  gate_docker
  maybe_stop_after docker

  gate_stack_ready
  maybe_stop_after stack-ready

  gate_seed
  maybe_stop_after seed

  resolve_world_identity
  resolve_sandbox_root

  gate_app_launch
  maybe_stop_after app-launch

  gate_keypackage_resolvable
  maybe_stop_after keypackage-resolvable

  gate_squad_invited
  maybe_stop_after squad-invited

  gate_welcome_accepted
  maybe_stop_after welcome-accepted

  gate_history_visible
  maybe_stop_after history-visible

  merge_world_block
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
