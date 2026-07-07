#!/usr/bin/env bash
set -euo pipefail

# Verify the host environment has the tools required by the Pacto dev environment.
#
# Prints remediation steps for anything missing. Run this before `make up` or
# `make check` to catch missing toolchains early.

export PATH="$HOME/.foundry/bin:$HOME/.cargo/bin:$HOME/.aztec/bin:$HOME/.local/bin:$PATH"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

failed=0
warned=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; failed=1; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; warned=1; }

REMEDY_MACOS="    ${YELLOW}Remedy:${NC} run ./setup-macos-arm64.sh"
REMEDY_LINUX="    ${YELLOW}Remedy:${NC} run sudo ./setup-ubuntu-lts.sh"
REMEDY_UNKNOWN="    ${YELLOW}Remedy:${NC} run the appropriate setup script for your platform (./setup-macos-arm64.sh or sudo ./setup-ubuntu-lts.sh)"

detect_platform() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux) echo "linux" ;;
    *) echo "unknown" ;;
  esac
}

print_remedy() {
  local platform="$1"
  case "$platform" in
    macos) echo -e "$REMEDY_MACOS" ;;
    linux) echo -e "$REMEDY_LINUX" ;;
    *) echo -e "$REMEDY_UNKNOWN" ;;
  esac
}

# Print a command's version, or "unknown" if it doesn't support --version.
version_of() {
  local cmd="$1"
  case "$cmd" in
    socat)
      "$cmd" -V 2>&1 | grep "^socat version" | head -1 || echo "version unknown"
      ;;
    *)
      "$cmd" --version 2>/dev/null | head -1 || echo "version unknown"
      ;;
  esac
}

# Check for a single command.
#   $1 = command name (or quoted command with args)
#   $2 = human-readable name
#   $3 = 1 if required, 0 if optional

check_command() {
  local cmd="$1"
  local name="$2"
  local required="${3:-1}"

  if command -v "$cmd" >/dev/null 2>&1; then
    pass "$name: $(version_of "$cmd")"
  elif [ "$required" = "1" ]; then
    fail "$name is not installed or not on PATH"
    print_remedy "$PLATFORM"
  else
    warn "$name is not installed or not on PATH (optional)"
  fi
}

# Check for a Docker Compose plugin, which is a subcommand, not a binary.
check_docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    pass "Docker Compose plugin: $(docker compose version --short 2>/dev/null || echo "version unknown")"
  else
    fail "Docker Compose plugin is not available"
    print_remedy "$PLATFORM"
  fi
}

main() {
  PLATFORM=$(detect_platform)

  echo "Pacto dev-env host environment verification"
  echo "============================================"
  echo
  echo "Platform: $PLATFORM"
  echo

  echo "Container runtime:"
  check_command docker "Docker"
  check_docker_compose

  echo
  echo "Version control:"
  check_command git "Git"

  echo
  echo "Rust toolchain:"
  check_command rustc "rustc"
  check_command cargo "cargo"

  echo
  echo "Node.js tooling:"
  check_command node "Node.js"
  check_command pnpm "pnpm"

  echo
  echo "Foundry (EVM):"
  check_command forge "forge"
  check_command cast "cast"
  check_command anvil "anvil"
  check_command chisel "chisel" 0

  echo
  echo "General utilities:"
  check_command jq "jq"
  check_command socat "socat"
  check_command websocat "websocat"

  echo
  echo "Aztec (optional):"
  check_command aztec-sandbox "aztec-sandbox" 0

  echo
  if [ "$failed" -eq 0 ] && [ "$warned" -eq 0 ]; then
    echo -e "${GREEN}All required tools are installed.${NC}"
    exit 0
  elif [ "$failed" -eq 0 ]; then
    echo -e "${YELLOW}All required tools are installed; optional tools are missing.${NC}"
    exit 0
  else
    echo -e "${RED}Some required tools are missing. Run the setup script for your platform.${NC}"
    exit 1
  fi
}

main
