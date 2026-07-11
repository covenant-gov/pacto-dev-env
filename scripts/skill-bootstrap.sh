#!/usr/bin/env bash
set -euo pipefail

# Bootstrap helper for the pacto-dev-env Claude Code skill.
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

start_services() {
  echo "[bootstrap] Starting default dev stack..."
  make up
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
