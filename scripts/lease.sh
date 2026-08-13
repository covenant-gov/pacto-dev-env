#!/usr/bin/env bash
set -euo pipefail

# Portable shared/exclusive lease over the one shared local stack (U16,
# R19/KTD9): stops one agent's reseed from silently destroying another
# agent's mid-scenario sandbox state.
#
# macOS ships no flock(1), so the primitive is atomic directory creation
# (mkdir succeeds for exactly one racer) plus a record of holder identity,
# pid, and timestamp -- not a file lock. A running sandbox holds a *shared*
# lease for its whole lifetime; a destructive operation (reseed, chain
# reset) takes an *exclusive* one, which conflicts with every shared or
# exclusive holder. Acquisition fails immediately by default, naming every
# current holder; waiting is opt-in via --wait and still names the holder(s)
# on timeout. A holder whose recorded pid is no longer alive is reclaimed
# lazily on the next acquisition attempt, so a crashed agent cannot wedge
# the lease. Release is idempotent.
#
# On-disk layout under one lease's root ($LEASE_DIR/<name>/):
#   exclusive/holder.json   present iff an exclusive holder exists (the
#                            directory itself is the mkdir-based lock)
#   shared/<id>/holder.json one directory per concurrent shared holder
#   .mutex/                 short-lived internal lock serializing reads and
#                            writes of the two directories above; never held
#                            longer than one acquire/release attempt
#
# Sourced by other scripts for the lease_acquire / lease_release /
# lease_status functions, or run directly as a CLI:
#
#   ./scripts/lease.sh acquire exclusive "reseed" --wait 30
#   ./scripts/lease.sh release <lease-id>
#   ./scripts/lease.sh status
#   ./scripts/lease.sh run exclusive "reseed" -- make reset up seed
#
# Env:
#   PACTO_LEASE_DIR   root directory for every lease, shared by every
#                      worktree on this machine because the stack itself is
#                      one shared resource per machine (default: a fixed
#                      path under the OS temp dir, matching pacto-app's
#                      scripts/dev-ports.mjs claim-dir convention).

LEASE_RED='\033[0;31m'
LEASE_YELLOW='\033[1;33m'
LEASE_NC='\033[0m'

lease_err()  { echo -e "${LEASE_RED}[lease]${LEASE_NC} $*" >&2; }
lease_warn() { echo -e "${LEASE_YELLOW}[lease]${LEASE_NC} $*" >&2; }

LEASE_DEFAULT_NAME="stack"
LEASE_DEFAULT_DIR="${PACTO_LEASE_DIR:-${TMPDIR:-/tmp}/pacto-dev-env-lease}"
LEASE_POLL_INTERVAL_DEFAULT="${PACTO_LEASE_POLL_INTERVAL:-1}"
LEASE_MUTEX_ATTEMPTS_DEFAULT="${PACTO_LEASE_MUTEX_ATTEMPTS:-200}"
LEASE_MUTEX_STEP="${PACTO_LEASE_MUTEX_STEP:-0.05}"

# --- pid liveness ----------------------------------------------------------

# True when $1 is a live pid. kill -0 fails on both "no such process" (dead)
# and EPERM ("exists, owned by someone else" -- still alive; see
# pacto-app's scripts/dev-ports.mjs isPidAlive for the same distinction).
# ps -p sees a pid's process-table entry independent of signal permission on
# both macOS and Linux, so it corroborates the EPERM case without depending
# on kill's locale-specific error text.
lease_pid_alive() {
  local pid="$1"
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 0 ] || return 1
  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  ps -p "$pid" >/dev/null 2>&1
}

# --- internal mutex: serializes reads/writes of exclusive/ and shared/ -----

lease_mutex_dir() { printf '%s/.mutex' "$1"; }

lease_mutex_acquire() {
  local root="$1" mutex attempt owner_pid
  mutex="$(lease_mutex_dir "$root")"
  attempt=1
  while [ "$attempt" -le "$LEASE_MUTEX_ATTEMPTS_DEFAULT" ]; do
    if mkdir "$mutex" 2>/dev/null; then
      printf '%s\n' "$$" >"$mutex/owner.pid" 2>/dev/null || true
      return 0
    fi
    owner_pid=""
    [ -f "$mutex/owner.pid" ] && owner_pid="$(cat "$mutex/owner.pid" 2>/dev/null || true)"
    if [ -n "$owner_pid" ] && ! lease_pid_alive "$owner_pid"; then
      # The previous holder died mid-critical-section; reclaim its mutex
      # the same way a lease itself is reclaimed.
      rm -rf "$mutex" 2>/dev/null || true
      continue
    fi
    sleep "$LEASE_MUTEX_STEP"
    attempt=$((attempt + 1))
  done
  lease_err "timed out waiting for the internal lease mutex at $mutex"
  return 1
}

lease_mutex_release() {
  rm -rf "$(lease_mutex_dir "$1")" 2>/dev/null || true
}

# --- holder records ---------------------------------------------------------

lease_write_record() {
  local file="$1" mode="$2" holder="$3" pid="$4" acquired="$5" reason="$6"
  jq -n --arg mode "$mode" --arg holder "$holder" --argjson pid "$pid" \
    --arg acquiredAt "$acquired" --arg reason "$reason" \
    '{mode: $mode, holder: $holder, pid: $pid, acquiredAt: $acquiredAt}
     + (if $reason != "" then {reason: $reason} else {} end)' \
    >"$file"
}

lease_record_pid() {
  jq -r '.pid // empty' "$1" 2>/dev/null
}

# True when $1/shared has at least one holder directory.
lease_has_shared_holders() {
  local root="$1" d
  [ -d "$root/shared" ] || return 1
  for d in "$root/shared"/*/; do
    [ -d "$d" ] && return 0
  done
  return 1
}

# Removes any holder record (exclusive or shared) whose recorded pid is no
# longer alive. Must be called with the mutex held.
lease_prune() {
  local root="$1" pid d
  if [ -d "$root/exclusive" ]; then
    pid="$(lease_record_pid "$root/exclusive/holder.json")"
    if [ -z "$pid" ] || ! lease_pid_alive "$pid"; then
      rm -rf "$root/exclusive"
    fi
  fi
  if [ -d "$root/shared" ]; then
    for d in "$root/shared"/*/; do
      [ -d "$d" ] || continue
      pid="$(lease_record_pid "${d}holder.json")"
      if [ -z "$pid" ] || ! lease_pid_alive "$pid"; then
        rm -rf "$d"
      fi
    done
  fi
}

lease_find_shared_by_pid() {
  local root="$1" pid="$2" d found_pid
  [ -d "$root/shared" ] || return 0
  for d in "$root/shared"/*/; do
    [ -d "$d" ] || continue
    found_pid="$(lease_record_pid "${d}holder.json")"
    if [ "$found_pid" = "$pid" ]; then
      basename "${d%/}"
      return 0
    fi
  done
  return 0
}

lease_describe_one() {
  local mode="$1" file="$2" holder pid acquired reason
  holder="$(jq -r '.holder // "unknown"' "$file" 2>/dev/null)"
  pid="$(jq -r '.pid // "unknown"' "$file" 2>/dev/null)"
  acquired="$(jq -r '.acquiredAt // "unknown"' "$file" 2>/dev/null)"
  reason="$(jq -r '.reason // empty' "$file" 2>/dev/null)"
  if [ -n "$reason" ]; then
    printf '  - %s: %s (pid %s, since %s) -- %s\n' "$mode" "$holder" "$pid" "$acquired" "$reason"
  else
    printf '  - %s: %s (pid %s, since %s)\n' "$mode" "$holder" "$pid" "$acquired"
  fi
}

# Human-readable listing of every current holder. Must be called with the
# mutex held (or immediately after lease_prune under it) for a consistent
# view.
lease_describe_holders() {
  local root="$1" out="" d
  if [ -d "$root/exclusive" ]; then
    out="${out}$(lease_describe_one exclusive "$root/exclusive/holder.json")"$'\n'
  fi
  if [ -d "$root/shared" ]; then
    for d in "$root/shared"/*/; do
      [ -d "$d" ] || continue
      out="${out}$(lease_describe_one shared "${d}holder.json")"$'\n'
    done
  fi
  printf '%s' "$out"
}

# --- acquire / release / status --------------------------------------------

# One mutex-protected attempt. Prints "OK:<lease-id>" on success or "BUSY"
# when the lease cannot be taken right now; never fails the calling shell.
lease_try_acquire() {
  local root="$1" mode="$2" holder="$3" pid="$4" reason="$5"
  mkdir -p "$root/shared"
  if ! lease_mutex_acquire "$root"; then
    printf 'BUSY\n'
    return 0
  fi

  lease_prune "$root"

  local now id
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [ "$mode" = "exclusive" ]; then
    if lease_has_shared_holders "$root" || [ -d "$root/exclusive" ]; then
      lease_mutex_release "$root"
      printf 'BUSY\n'
      return 0
    fi
    id="exclusive-$pid-$(date +%s)-$RANDOM"
    mkdir "$root/exclusive"
    printf '%s' "$id" >"$root/exclusive/lease-id"
    lease_write_record "$root/exclusive/holder.json" "$mode" "$holder" "$pid" "$now" "$reason"
    lease_mutex_release "$root"
    printf 'OK:%s\n' "$id"
    return 0
  fi

  # shared
  if [ -d "$root/exclusive" ]; then
    lease_mutex_release "$root"
    printf 'BUSY\n'
    return 0
  fi

  local existing
  existing="$(lease_find_shared_by_pid "$root" "$pid")"
  if [ -n "$existing" ]; then
    # Idempotent: this pid already holds a shared record (e.g. dev-world.sh
    # re-registering an already-running sandbox app); reuse it rather than
    # creating a duplicate.
    lease_mutex_release "$root"
    printf 'OK:%s\n' "$existing"
    return 0
  fi

  id="shared-$pid-$(date +%s)-$RANDOM"
  mkdir "$root/shared/$id"
  lease_write_record "$root/shared/$id/holder.json" "$mode" "$holder" "$pid" "$now" "$reason"
  lease_mutex_release "$root"
  printf 'OK:%s\n' "$id"
  return 0
}

# lease_acquire <shared|exclusive> <holder-label>
#   [--name NAME] [--lease-dir DIR] [--pid PID] [--reason TEXT]
#   [--wait SECONDS] [--poll-interval SECONDS]
#
# Prints the acquired lease id to stdout and returns 0 on success. On
# failure, names every current holder on stderr and returns 1. Fails
# immediately by default (--wait 0); with --wait N it polls for up to N
# seconds before giving up.
lease_acquire() {
  local mode="$1" holder="$2"
  shift 2
  local name="$LEASE_DEFAULT_NAME" lease_dir="$LEASE_DEFAULT_DIR" pid="$$" \
    reason="" wait_secs="0" poll="$LEASE_POLL_INTERVAL_DEFAULT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --lease-dir) lease_dir="$2"; shift 2 ;;
      --pid) pid="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      --wait) wait_secs="$2"; shift 2 ;;
      --poll-interval) poll="$2"; shift 2 ;;
      *) lease_err "lease_acquire: unknown option $1"; return 2 ;;
    esac
  done

  case "$mode" in
    shared | exclusive) ;;
    *) lease_err "lease_acquire: mode must be 'shared' or 'exclusive', got '$mode'"; return 2 ;;
  esac
  case "$pid" in '' | *[!0-9]*) lease_err "lease_acquire: --pid must be a positive integer, got '$pid'"; return 2 ;; esac

  local root="$lease_dir/$name"
  mkdir -p "$root"

  local attempts=1
  if [ "$wait_secs" -gt 0 ] 2>/dev/null; then
    attempts=$(((wait_secs + poll - 1) / poll))
    [ "$attempts" -ge 1 ] || attempts=1
  fi

  local attempt=1 result
  while [ "$attempt" -le "$attempts" ]; do
    result="$(lease_try_acquire "$root" "$mode" "$holder" "$pid" "$reason")"
    case "$result" in
      OK:*)
        printf '%s\n' "${result#OK:}"
        return 0
        ;;
    esac
    if [ "$attempt" -lt "$attempts" ]; then
      sleep "$poll"
    fi
    attempt=$((attempt + 1))
  done

  local holders_msg=""
  if lease_mutex_acquire "$root"; then
    lease_prune "$root"
    holders_msg="$(lease_describe_holders "$root")"
    lease_mutex_release "$root"
  fi

  if [ "$wait_secs" -gt 0 ] 2>/dev/null; then
    lease_err "timed out after ${wait_secs}s waiting for $mode lease '$name'; current holder(s):"
  else
    lease_err "$mode lease '$name' is busy; current holder(s):"
  fi
  if [ -n "$holders_msg" ]; then
    printf '%s\n' "$holders_msg" | while IFS= read -r line; do
      [ -n "$line" ] && lease_err "$line"
    done
  else
    lease_err "  (none found -- lost a race with a concurrent release; retry)"
  fi
  return 1
}

# lease_release <lease-id> [--name NAME] [--lease-dir DIR]
# Idempotent: releasing an unheld or already-released lease is not an error.
lease_release() {
  local id="$1"
  shift
  local name="$LEASE_DEFAULT_NAME" lease_dir="$LEASE_DEFAULT_DIR"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --lease-dir) lease_dir="$2"; shift 2 ;;
      *) lease_err "lease_release: unknown option $1"; return 2 ;;
    esac
  done
  [ -n "$id" ] || { lease_err "lease_release: lease id required"; return 2; }

  local root="$lease_dir/$name"
  [ -d "$root" ] || return 0

  if ! lease_mutex_acquire "$root"; then
    lease_warn "could not acquire the internal mutex to release '$id'; leaving it for lazy pid-based reclaim"
    return 0
  fi

  case "$id" in
    exclusive-*)
      if [ -d "$root/exclusive" ]; then
        local recorded=""
        [ -f "$root/exclusive/lease-id" ] && recorded="$(cat "$root/exclusive/lease-id" 2>/dev/null || true)"
        if [ -z "$recorded" ] || [ "$recorded" = "$id" ]; then
          rm -rf "$root/exclusive"
        fi
      fi
      ;;
    *)
      rm -rf "${root:?}/shared/$id" 2>/dev/null || true
      ;;
  esac

  lease_mutex_release "$root"
  return 0
}

# lease_status [--name NAME] [--lease-dir DIR]
# Prints every current holder (after pruning stale ones), or "no holders".
lease_status() {
  local name="$LEASE_DEFAULT_NAME" lease_dir="$LEASE_DEFAULT_DIR"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --lease-dir) lease_dir="$2"; shift 2 ;;
      *) lease_err "lease_status: unknown option $1"; return 2 ;;
    esac
  done
  local root="$lease_dir/$name"
  if [ ! -d "$root" ]; then
    echo "no holders"
    return 0
  fi
  local msg=""
  if lease_mutex_acquire "$root"; then
    lease_prune "$root"
    msg="$(lease_describe_holders "$root")"
    lease_mutex_release "$root"
  fi
  if [ -z "$msg" ]; then
    echo "no holders"
  else
    printf '%s' "$msg"
  fi
}

# --- CLI ---------------------------------------------------------------

lease_cli_usage() {
  cat <<'EOF'
Usage:
  lease.sh acquire <shared|exclusive> <holder-label> [--name NAME]
                    [--reason TEXT] [--pid PID] [--wait SECONDS]
                    [--poll-interval SECONDS] [--lease-dir DIR]
  lease.sh release <lease-id> [--name NAME] [--lease-dir DIR]
  lease.sh status [--name NAME] [--lease-dir DIR]
  lease.sh run <shared|exclusive> <holder-label> [--name NAME]
               [--reason TEXT] [--wait SECONDS] [--poll-interval SECONDS]
               [--lease-dir DIR] -- CMD [ARGS...]

Env:
  PACTO_LEASE_DIR  root directory for every lease
                    (default: ${TMPDIR:-/tmp}/pacto-dev-env-lease)
EOF
}

_lease_run_cleanup() {
  lease_release "$_LEASE_RUN_ID" --name "$_LEASE_RUN_NAME" --lease-dir "$_LEASE_RUN_DIR"
}

lease_cli_run() {
  local mode="$1" holder="$2"
  shift 2
  local name="$LEASE_DEFAULT_NAME" lease_dir="$LEASE_DEFAULT_DIR" reason="" \
    wait_secs="0" poll="$LEASE_POLL_INTERVAL_DEFAULT"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --lease-dir) lease_dir="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      --wait) wait_secs="$2"; shift 2 ;;
      --poll-interval) poll="$2"; shift 2 ;;
      --) shift; break ;;
      *) lease_err "lease run: unexpected argument '$1' (expected -- before the command)"; return 2 ;;
    esac
  done
  [ $# -gt 0 ] || { lease_err "lease run: no command given after --"; return 2; }

  local id
  id="$(lease_acquire "$mode" "$holder" --name "$name" --lease-dir "$lease_dir" \
    --pid "$$" --reason "$reason" --wait "$wait_secs" --poll-interval "$poll")"

  _LEASE_RUN_ID="$id"
  _LEASE_RUN_NAME="$name"
  _LEASE_RUN_DIR="$lease_dir"
  trap _lease_run_cleanup EXIT INT TERM

  "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  case "$cmd" in
    acquire)
      shift
      mode="${1:-}"
      cli_holder="${2:-}"
      [ -n "$mode" ] && [ -n "$cli_holder" ] || { lease_cli_usage >&2; exit 2; }
      shift 2
      lease_acquire "$mode" "$cli_holder" "$@"
      ;;
    release)
      shift
      cli_id="${1:-}"
      [ -n "$cli_id" ] || { lease_cli_usage >&2; exit 2; }
      shift
      lease_release "$cli_id" "$@"
      ;;
    status)
      shift
      lease_status "$@"
      ;;
    run)
      shift
      mode="${1:-}"
      cli_holder="${2:-}"
      [ -n "$mode" ] && [ -n "$cli_holder" ] || { lease_cli_usage >&2; exit 2; }
      shift 2
      lease_cli_run "$mode" "$cli_holder" "$@"
      ;;
    -h | --help | help | "")
      lease_cli_usage
      ;;
    *)
      lease_err "unknown subcommand: $cmd"
      lease_cli_usage >&2
      exit 2
      ;;
  esac
fi
