#!/usr/bin/env bash
set -euo pipefail

# Test suite for scripts/lease.sh (U16): the portable shared/exclusive lease
# over the one shared local stack. No Docker, no network, and no dependency
# on the real stack being up -- every holder is either this test process's
# own pid or a throwaway background `sleep`, and every case gets its own
# throwaway lease directory so cases never interfere with each other.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LEASE_SH="$REPO_ROOT/scripts/lease.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

failed=0
pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; failed=1; }

TEST_TMPDIR="$(mktemp -d)"
LIVE_PIDS=()
# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {
  local p
  for p in "${LIVE_PIDS[@]:-}"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
  done
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

# spawn_holder -- a pid this process can see as alive for the case's
# duration, standing in for a live agent/sandbox process.
spawn_holder() {
  sleep 300 >/dev/null 2>&1 &
  local p=$!
  LIVE_PIDS+=("$p")
  echo "$p"
}

# dead_pid -- a pid guaranteed dead: started and reaped immediately,
# standing in for a crashed agent that never released its lease.
dead_pid() {
  (exit 0) &
  local p=$!
  wait "$p" 2>/dev/null || true
  echo "$p"
}

# fresh_lease_dir <case-name> -- an isolated --lease-dir per test case.
fresh_lease_dir() {
  local dir="$TEST_TMPDIR/$1"
  mkdir -p "$dir"
  echo "$dir"
}

# run_lease <args...> -- invokes lease.sh as the real CLI subprocess (the
# same entry point the Makefile and the other scripts use) and sets
# LAST_STATUS, LAST_STDOUT, LAST_STDERR.
run_lease() {
  local out err
  out="$(mktemp)"
  err="$(mktemp)"
  if "$LEASE_SH" "$@" >"$out" 2>"$err"; then
    LAST_STATUS=0
  else
    LAST_STATUS=$?
  fi
  LAST_STDOUT="$(cat "$out")"
  LAST_STDERR="$(cat "$err")"
  rm -f "$out" "$err"
}

case_exclusive_succeeds_when_free() {
  local dir
  dir="$(fresh_lease_dir exclusive_free)"
  run_lease acquire exclusive "captain" --lease-dir "$dir" --pid "$$"
  if [[ "$LAST_STATUS" -eq 0 ]] && [[ "$LAST_STDOUT" == exclusive-* ]]; then
    pass "exclusive acquisition succeeds when no lease is held"
  else
    fail "expected exit 0 with an exclusive-* lease id, got exit $LAST_STATUS: stdout='$LAST_STDOUT' stderr='$LAST_STDERR'"
  fi
}

case_exclusive_fails_naming_shared_holder() {
  local dir pid
  dir="$(fresh_lease_dir exclusive_vs_shared)"
  pid="$(spawn_holder)"

  run_lease acquire shared "sandbox-app" --lease-dir "$dir" --pid "$pid" --reason "dev-world sandbox"
  [[ "$LAST_STATUS" -eq 0 ]] || { fail "setup: shared acquire should have succeeded: $LAST_STDERR"; return; }

  run_lease acquire exclusive "reseed" --lease-dir "$dir" --pid "$$"
  if [[ "$LAST_STATUS" -ne 0 ]] && grep -q "sandbox-app" <<<"$LAST_STDERR" && grep -q "pid $pid" <<<"$LAST_STDERR"; then
    pass "exclusive acquisition fails immediately when a shared lease is held, naming the holder"
  else
    fail "expected immediate failure naming 'sandbox-app' (pid $pid), got exit $LAST_STATUS: $LAST_STDERR"
  fi
}

case_two_shared_coexist() {
  local dir pid_a pid_b id_a status_a id_b status_b
  dir="$(fresh_lease_dir two_shared)"
  pid_a="$(spawn_holder)"
  pid_b="$(spawn_holder)"

  run_lease acquire shared "sandbox-A" --lease-dir "$dir" --pid "$pid_a"
  id_a="$LAST_STDOUT"
  status_a="$LAST_STATUS"
  run_lease acquire shared "sandbox-B" --lease-dir "$dir" --pid "$pid_b"
  id_b="$LAST_STDOUT"
  status_b="$LAST_STATUS"

  run_lease status --lease-dir "$dir"
  if [[ "$status_a" -eq 0 ]] && [[ "$status_b" -eq 0 ]] && [[ "$id_a" != "$id_b" ]] &&
    grep -q "pid $pid_a" <<<"$LAST_STDOUT" && grep -q "pid $pid_b" <<<"$LAST_STDOUT"; then
    pass "two shared acquisitions coexist"
  else
    fail "expected two distinct coexisting shared leases; a=$status_a/$id_a b=$status_b/$id_b status='$LAST_STDOUT'"
  fi
}

case_dead_exclusive_pid_reclaimed() {
  local dir dpid
  dir="$(fresh_lease_dir dead_exclusive_reclaim)"
  dpid="$(dead_pid)"

  run_lease acquire exclusive "crashed-agent" --lease-dir "$dir" --pid "$dpid"
  [[ "$LAST_STATUS" -eq 0 ]] || { fail "setup: could not seed a dead-pid exclusive holder: $LAST_STDERR"; return; }

  run_lease acquire exclusive "next-agent" --lease-dir "$dir" --pid "$$"
  if [[ "$LAST_STATUS" -eq 0 ]] && [[ "$LAST_STDOUT" == exclusive-* ]]; then
    pass "an exclusive lease whose recorded pid is dead is reclaimed rather than blocking forever"
  else
    fail "expected the dead-holder lease to be reclaimed and a fresh exclusive lease granted, got exit $LAST_STATUS: $LAST_STDERR"
  fi
}

case_dead_shared_pid_reclaimed() {
  local dir dpid
  dir="$(fresh_lease_dir dead_shared_reclaim)"
  dpid="$(dead_pid)"

  run_lease acquire shared "crashed-sandbox" --lease-dir "$dir" --pid "$dpid"
  [[ "$LAST_STATUS" -eq 0 ]] || { fail "setup: could not seed a dead-pid shared holder: $LAST_STDERR"; return; }

  run_lease acquire exclusive "reseed" --lease-dir "$dir" --pid "$$"
  if [[ "$LAST_STATUS" -eq 0 ]]; then
    pass "a dead shared holder (e.g. a killed sandbox) is reclaimed instead of blocking an exclusive acquisition forever"
  else
    fail "expected the dead shared holder to be pruned, got exit $LAST_STATUS: $LAST_STDERR"
  fi
}

case_wait_succeeds_once_released() {
  local dir pid held_id start end releaser
  dir="$(fresh_lease_dir wait_release)"
  pid="$(spawn_holder)"

  run_lease acquire exclusive "reseed-a" --lease-dir "$dir" --pid "$pid"
  held_id="$LAST_STDOUT"
  [[ "$LAST_STATUS" -eq 0 ]] || { fail "setup: could not seed exclusive holder: $LAST_STDERR"; return; }

  (
    sleep 1
    "$LEASE_SH" release "$held_id" --lease-dir "$dir"
  ) >/dev/null 2>&1 &
  releaser=$!
  LIVE_PIDS+=("$releaser")

  start="$(date +%s)"
  run_lease acquire exclusive "reseed-b" --lease-dir "$dir" --pid "$$" --wait 5 --poll-interval 1
  end="$(date +%s)"
  wait "$releaser" 2>/dev/null || true

  if [[ "$LAST_STATUS" -eq 0 ]] && [[ "$LAST_STDOUT" == exclusive-* ]] && ((end - start < 5)); then
    pass "opt-in waiting acquires once the holder releases (took $((end - start))s)"
  else
    fail "expected the waiting acquire to succeed promptly after release, got exit $LAST_STATUS after $((end - start))s: $LAST_STDERR"
  fi
}

case_wait_times_out_naming_holder() {
  local dir pid
  dir="$(fresh_lease_dir wait_timeout)"
  pid="$(spawn_holder)"

  run_lease acquire exclusive "stuck-reseed" --lease-dir "$dir" --pid "$pid" --reason "simulated stuck reseed"
  [[ "$LAST_STATUS" -eq 0 ]] || { fail "setup: could not seed exclusive holder: $LAST_STDERR"; return; }

  run_lease acquire exclusive "impatient-agent" --lease-dir "$dir" --pid "$$" --wait 2 --poll-interval 1
  if [[ "$LAST_STATUS" -ne 0 ]] && grep -q "timed out" <<<"$LAST_STDERR" && grep -q "stuck-reseed" <<<"$LAST_STDERR"; then
    pass "opt-in waiting times out with a named holder"
  else
    fail "expected a timeout naming 'stuck-reseed', got exit $LAST_STATUS: $LAST_STDERR"
  fi
}

case_release_idempotent() {
  local dir status1 id status2 status3
  dir="$(fresh_lease_dir release_idempotent)"

  run_lease release "shared-999999-0-0" --lease-dir "$dir"
  status1="$LAST_STATUS"

  run_lease acquire exclusive "captain" --lease-dir "$dir" --pid "$$"
  id="$LAST_STDOUT"

  run_lease release "$id" --lease-dir "$dir"
  status2="$LAST_STATUS"
  run_lease release "$id" --lease-dir "$dir"
  status3="$LAST_STATUS"

  if [[ "$status1" -eq 0 ]] && [[ "$status2" -eq 0 ]] && [[ "$status3" -eq 0 ]]; then
    pass "release is idempotent: releasing an unheld or already-released lease is not an error"
  else
    fail "expected every release to exit 0, got unheld=$status1 first=$status2 second=$status3"
  fi
}

case_run_releases_after_success() {
  local dir
  dir="$(fresh_lease_dir run_success)"
  if "$LEASE_SH" run exclusive "make seed" --lease-dir "$dir" -- true; then
    run_lease status --lease-dir "$dir"
    if [[ "$LAST_STDOUT" == "no holders" ]]; then
      pass "'lease.sh run' releases the lease after the guarded command succeeds"
    else
      fail "expected no holders after 'lease.sh run' completed, got: $LAST_STDOUT"
    fi
  else
    fail "'lease.sh run' should have succeeded running a trivial command"
  fi
}

case_run_releases_after_failure() {
  local dir
  dir="$(fresh_lease_dir run_failure)"
  if "$LEASE_SH" run exclusive "failing-op" --lease-dir "$dir" -- false; then
    fail "'lease.sh run' should propagate the guarded command's failure"
    return
  fi
  run_lease status --lease-dir "$dir"
  if [[ "$LAST_STDOUT" == "no holders" ]]; then
    pass "'lease.sh run' releases the lease even when the guarded command fails"
  else
    fail "expected no holders after a failing guarded command, got: $LAST_STDOUT"
  fi
}

# AE6: agent A is mid-scenario (a shared lease tied to its sandbox app's
# pid); agent B triggers a reseed (an exclusive acquisition) and it fails,
# naming agent A's sandbox; once agent A's sandbox process exits, the
# reseed proceeds. Mirrors exactly what scripts/dev-world.sh and the
# Makefile's reseed wiring call (U16c) -- no live stack required.
case_ae6_reseed_blocked_then_proceeds() {
  local dir app_pid
  dir="$(fresh_lease_dir ae6)"
  app_pid="$(spawn_holder)"

  run_lease acquire shared "dev-world:feat-agent-a" --lease-dir "$dir" \
    --pid "$app_pid" --reason "sandbox mid-scenario"
  [[ "$LAST_STATUS" -eq 0 ]] || { fail "AE6 setup: could not take the sandbox's shared lease: $LAST_STDERR"; return; }

  run_lease acquire exclusive "make reseed" --lease-dir "$dir" --pid "$$" \
    --reason "reset stack and redeploy"
  if [[ "$LAST_STATUS" -eq 0 ]]; then
    fail "AE6: reseed should not have proceeded while agent A's sandbox is mid-scenario"
    return
  fi
  if ! grep -q "dev-world:feat-agent-a" <<<"$LAST_STDERR"; then
    fail "AE6: reseed failure did not name agent A's sandbox holder: $LAST_STDERR"
    return
  fi

  # Agent A's sandbox process exits (crash or clean shutdown); dev-world.sh
  # never calls lease_release itself, so this relies on the same lazy
  # pid-liveness reclaim exercised by case_dead_shared_pid_reclaimed above.
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true

  run_lease acquire exclusive "make reseed" --lease-dir "$dir" --pid "$$" \
    --reason "reset stack and redeploy"
  if [[ "$LAST_STATUS" -eq 0 ]]; then
    pass "AE6: a reseed from another worktree fails naming the holder, then proceeds once the sandbox exits"
  else
    fail "AE6: reseed should have proceeded once agent A's sandbox process exited, got exit $LAST_STATUS: $LAST_STDERR"
  fi
}

main() {
  echo "Lease primitive test suite (U16)"
  echo "===================================="

  case_exclusive_succeeds_when_free
  case_exclusive_fails_naming_shared_holder
  case_two_shared_coexist
  case_dead_exclusive_pid_reclaimed
  case_dead_shared_pid_reclaimed
  case_wait_succeeds_once_released
  case_wait_times_out_naming_holder
  case_release_idempotent
  case_run_releases_after_success
  case_run_releases_after_failure
  case_ae6_reseed_blocked_then_proceeds

  echo
  if [[ "$failed" -eq 0 ]]; then
    echo -e "${GREEN}All lease tests passed.${NC}"
    exit 0
  else
    echo -e "${RED}Some lease tests failed.${NC}"
    exit 1
  fi
}

main "$@"
