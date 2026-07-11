#!/usr/bin/env bash
set -euo pipefail

# Bootstrap helper for the pacto-dev-env skill.
# Intended to be run from inside the cloned pacto-dev-env repository.

PACTO_DEV_ENV_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACTO_BASE_DIR="$(dirname "$PACTO_DEV_ENV_DIR")"

REPOS="pacto-app pacto-gov pacto-bot-api pacto-aztec"

detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  if [[ "$os" == "Darwin" && "$arch" == "arm64" ]]; then
    echo "macos-arm64"
  elif [[ "$os" == "Linux" ]]; then
    # Check for supported Ubuntu LTS releases
    if [[ -f /etc/os-release ]]; then
      # shellcheck source=/dev/null
      source /etc/os-release
      case "$VERSION_ID" in
        "24.04"|"24.10"|"26.04")
          echo "ubuntu-lts"
          ;;
        *)
          echo "unsupported"
          ;;
      esac
    else
      echo "unsupported"
    fi
  else
    echo "unsupported"
  fi
}

run_setup() {
  local platform
  platform="$(detect_platform)"

  case "$platform" in
    macos-arm64)
      echo "[bootstrap] Running macOS arm64 setup..."
      ./setup-macos-arm64.sh "$PACTO_BASE_DIR"
      ;;
    ubuntu-lts)
      echo "[bootstrap] Running Ubuntu LTS setup..."
      sudo ./setup-ubuntu-lts.sh "$PACTO_BASE_DIR"
      ;;
    *)
      echo "[bootstrap] Unsupported platform. Supported: macOS arm64, Ubuntu 24.04/24.10/26.04."
      exit 1
      ;;
  esac
}

clone_siblings() {
  for repo in $REPOS; do
    local dest="$PACTO_BASE_DIR/$repo"
    if [[ -d "$dest" ]]; then
      echo "[bootstrap] $repo already present at $dest"
    else
      echo "[bootstrap] Cloning $repo..."
      git clone "https://github.com/covenant-gov/$repo.git" "$dest"
    fi
  done
}

has_bots_configured() {
  local config="$PACTO_DEV_ENV_DIR/pacto-bot-api.toml"
  [[ -f "$config" ]] && grep -q '^\[\[bots\]\]' "$config"
}

select_stack() {
  if [[ -n "${PACTO_START_MODE:-}" ]]; then
    echo "$PACTO_START_MODE"
    return
  fi

  if [[ ! -t 0 ]]; then
    echo "default"
    return
  fi

  echo
  echo "[bootstrap] Which service stack should be started?"
  echo "  1) default  - nostr-relay, anvil, pacto-bot-api (make up)"
  echo "  2) full     - default + aztec + bunker + seed (make up-all)"
  echo "  3) squad    - full + Nave Pirata squad (make seed-squad)"
  echo "  4) group    - full + squad + MLS group (make create-mls-group)"
  echo "  5) bots     - full + use existing bots from pacto-bot-api.toml"
  echo
  read -rp "Enter choice [1-5, default: 1]: " choice
  case "${choice:-1}" in
    2) echo "full" ;;
    3) echo "squad" ;;
    4) echo "group" ;;
    5) echo "bots" ;;
    *) echo "default" ;;
  esac
}

interview_stack() {
  if [[ -n "${PACTO_START_MODE:-}" ]]; then
    echo "$PACTO_START_MODE"
    return
  fi

  if [[ ! -t 0 ]]; then
    echo "default"
    return
  fi

  echo
  echo "[bootstrap] What do you want to do with the Pacto dev environment?"
  echo "  1) Connect a frontend like pacto-app to the local relay and chain."
  echo "  2) Test governance contracts, Aztec, or the bunker."
  echo "  3) Seed and inspect a Nave Pirata squad."
  echo "  4) Create an MLS group for encrypted messaging."
  echo "  5) Use bots already configured in pacto-bot-api.toml."
  echo "  6) I'm not sure — show me the raw stack options."
  echo
  read -rp "Enter choice [1-6, default: 1]: " choice
  case "${choice:-1}" in
    2) echo "full" ;;
    3) echo "squad" ;;
    4) echo "group" ;;
    5)
      if has_bots_configured; then
        echo "bots"
      else
        echo
        echo "[bootstrap] No bots are configured in pacto-bot-api.toml yet."
        echo "[bootstrap] Falling back to the raw stack menu so you can choose another option."
        echo
        select_stack
      fi
      ;;
    6) select_stack ;;
    *) echo "default" ;;
  esac
}

ensure_group_env() {
  if [[ -z "${RECIPIENT_NPUB:-}" ]]; then
    if [[ -t 0 ]]; then
      read -rp "RECIPIENT_NPUB (required for group creation): " RECIPIENT_NPUB
      export RECIPIENT_NPUB
    else
      echo "[bootstrap] RECIPIENT_NPUB is required for group mode. Set it and retry." >&2
      exit 1
    fi
  fi

  : "${BOT_ID:=bosun}"
  : "${GROUP_NAME:=local-dev-squad}"
  export BOT_ID GROUP_NAME
}

verify_bots_configured() {
  if ! has_bots_configured; then
    echo "[bootstrap] Bot mode requires pre-configured bots in pacto-bot-api.toml." >&2
    echo "[bootstrap] Create bots with pacto-bot-admin first, or choose a different mode." >&2
    exit 1
  fi
}

start_services() {
  local mode
  mode="$(interview_stack)"

  case "$mode" in
    full)
      echo "[bootstrap] Starting full dev stack (make up-all)..."
      make up-all
      ;;
    squad)
      echo "[bootstrap] Starting full dev stack and seeding a squad..."
      make up-all
      make seed-squad
      ;;
    group)
      ensure_group_env
      echo "[bootstrap] Starting full dev stack, seeding a squad, and creating an MLS group..."
      make up-all
      make seed-squad
      make create-mls-group
      ;;
    bots)
      verify_bots_configured
      echo "[bootstrap] Starting full dev stack with configured bots..."
      make up-all
      ;;
    *)
      echo "[bootstrap] Starting default dev stack (make up)..."
      make up
      ;;
  esac

  echo
  echo "[bootstrap] Stack mode: $mode"
}

main() {
  cd "$PACTO_DEV_ENV_DIR"

  echo "[bootstrap] Pacto dev environment: $PACTO_DEV_ENV_DIR"
  echo "[bootstrap] Pacto base directory: $PACTO_BASE_DIR"

  run_setup
  clone_siblings
  start_services

  echo
  echo "[bootstrap] Bootstrap complete. Run the following from any sibling repo to configure it:"
  echo "  /pacto-dev-env connect"
}

main "$@"
