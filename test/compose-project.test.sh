#!/usr/bin/env bash
set -euo pipefail

# Compose project identity test suite.
#
# Compose otherwise derives its project name from the invoking directory's
# basename, which breaks under git worktrees and non-default clone dir names
# (scripts/dev-world.sh silently addresses an empty "wrong" project instead
# of the shared stack). Asserts docker-compose.yml pins the name explicitly
# and that it stays stable regardless of cwd. `docker compose config` only
# parses the file locally, so no daemon needs to be reachable.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/docker-compose.yml"
EXPECTED_NAME="pacto-dev-env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

failed=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; failed=1; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }

case_pins_name_in_file() {
  local name_line
  name_line="$(grep -m1 -E '^name:[[:space:]]*' "$COMPOSE_FILE" || true)"
  if [[ "$name_line" == "name: $EXPECTED_NAME" ]]; then
    pass "docker-compose.yml pins top-level name: $EXPECTED_NAME"
  else
    fail "docker-compose.yml is missing a top-level 'name: $EXPECTED_NAME' key (got: '${name_line:-<none>}')"
  fi
}

case_name_stable_across_cwd() {
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    warn "docker compose plugin not found on PATH; skipping cwd cross-check"
    return
  fi

  local resolved_repo resolved_tmp tmp_cwd
  resolved_repo="$(cd "$REPO_ROOT" && docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])' 2>/dev/null || true)"

  tmp_cwd="$(mktemp -d)"
  resolved_tmp="$(cd "$tmp_cwd" && docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])' 2>/dev/null || true)"
  rm -rf "$tmp_cwd"

  if [[ "$resolved_repo" == "$EXPECTED_NAME" && "$resolved_tmp" == "$EXPECTED_NAME" ]]; then
    pass "resolved project name is '$EXPECTED_NAME' from both the repo root and an unrelated cwd"
  else
    fail "project name is not cwd-stable (from repo root: '${resolved_repo:-<empty>}', from unrelated cwd: '${resolved_tmp:-<empty>}')"
  fi
}

main() {
  echo "Compose project identity test suite"
  echo "===================================="

  case_pins_name_in_file
  case_name_stable_across_cwd

  echo
  if [[ "$failed" -eq 0 ]]; then
    echo -e "${GREEN}All compose-project tests passed.${NC}"
    exit 0
  else
    echo -e "${RED}Some compose-project tests failed.${NC}"
    exit 1
  fi
}

main "$@"
