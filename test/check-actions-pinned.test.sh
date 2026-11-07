#!/usr/bin/env bash
# Unit coverage for scripts/check-actions-pinned.sh (no network, no Docker).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/check-actions-pinned.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

assert_ok() {
  local name="$1"
  shift
  if "$@" >/dev/null; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name" >&2
    fail=$((fail + 1))
  fi
}

assert_fail() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: expected failure: $name" >&2
    fail=$((fail + 1))
  else
    echo "PASS: $name"
    pass=$((pass + 1))
  fi
}

assert_ok "repo workflows are SHA-pinned" "$SCRIPT"

mkdir -p "$TMP/workflows"
cat >"$TMP/workflows/bad.yml" <<'EOF'
jobs:
  x:
    steps:
      - uses: actions/checkout@v6
EOF
assert_fail "detects tag-pinned Action" "$SCRIPT" "$TMP/workflows"

cat >"$TMP/workflows/bad.yml" <<'EOF'
jobs:
  x:
    steps:
      - uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10
EOF
assert_ok "accepts full SHA pin" "$SCRIPT" "$TMP/workflows"

cat >"$TMP/workflows/local.yml" <<'EOF'
jobs:
  x:
    steps:
      - uses: ./local-action
      - uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10
EOF
assert_ok "ignores local composite Action paths" "$SCRIPT" "$TMP/workflows"

echo
echo "check-actions-pinned tests: $pass passed, $fail failed"
exit "$fail"
