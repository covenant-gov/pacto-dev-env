#!/usr/bin/env bash
set -euo pipefail

# Ensure required sibling repositories are present for the Pacto dev environment.
#
# Usage:
#   ./scripts/ensure-sibling-repos.sh
#   ./scripts/ensure-sibling-repos.sh --yes   # auto-clone without prompting
#
# By default the script is interactive and offers to clone missing repos. In
# non-interactive environments (CI) use --yes to allow automatic cloning.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[ensure-sibling-repos]${NC} $*"; }
warn() { echo -e "${YELLOW}[ensure-sibling-repos]${NC} $*"; }
err()  { echo -e "${RED}[ensure-sibling-repos]${NC} $*" >&2; }

YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      YES=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [-y|--yes]"
      echo "Ensures sibling repositories required by the dev environment are cloned."
      echo "With --yes, missing repos are cloned automatically."
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      echo "Usage: $0 [-y|--yes]"
      exit 1
      ;;
  esac
done

expand_path() {
  local path="$1"
  # Expand a leading ~ to $HOME.
  echo "${path/#\~/$HOME}"
}

get_pacto_gov_dir() {
  if [ -n "${PACTO_GOV_DIR:-}" ]; then
    expand_path "$PACTO_GOV_DIR"
  else
    echo "$REPO_ROOT/../pacto-gov"
  fi
}

is_valid_pacto_gov() {
  local dir="$1"
  [ -d "$dir" ] && [ -f "$dir/script/Deploy.sol" ]
}

prompt() {
  local question="$1"
  local ans
  if [ "$YES" = "1" ]; then
    echo "$question [Y/n] y"
    return 0
  fi
  if [ ! -t 0 ]; then
    err "Cannot prompt in a non-interactive environment. Use --yes to proceed automatically."
    exit 1
  fi
  read -rp "$question [Y/n] " ans
  [[ "$ans" =~ ^[Yy]?$ ]]
}

clone_pacto_gov() {
  local dir="$1"
  local url="https://github.com/covenant-gov/pacto-gov.git"

  if [ -d "$dir" ]; then
    err "Directory exists but is not a valid pacto-gov repo: $dir"
    err "Remove it or set PACTO_GOV_DIR to the correct path."
    exit 1
  fi

  echo
  warn "Required sibling repo 'pacto-gov' is missing."
  echo -e "  ${BLUE}Expected:${NC} $dir"
  echo -e "  ${BLUE}Remote:${NC}  $url"
  echo

  if ! prompt "Clone pacto-gov now"; then
    err "Cannot continue without pacto-gov. Exiting."
    exit 1
  fi

  mkdir -p "$(dirname "$dir")"
  log "Cloning pacto-gov into $dir..."
  git clone "$url" "$dir"
}

ensure_pacto_gov_deps() {
  local dir="$1"

  # pnpm writes node_modules/.modules.yaml when the install is complete.
  if [ -d "$dir/node_modules" ] && [ -f "$dir/node_modules/.modules.yaml" ]; then
    log "pacto-gov dependencies are already installed"
    return 0
  fi

  if ! command -v pnpm >/dev/null 2>&1; then
    err "pnpm is required to install pacto-gov dependencies, but it's not on PATH."
    err "Run the host setup script (setup-macos-arm64.sh or setup-ubuntu-lts.sh) first."
    exit 1
  fi

  echo
  warn "pacto-gov dependencies are missing (node_modules not found)."
  echo -e "  ${BLUE}Directory:${NC} $dir"
  if ! prompt "Run pnpm install in pacto-gov now"; then
    err "Cannot continue without dependencies. Exiting."
    exit 1
  fi

  log "Running pnpm install in $dir..."
  (cd "$dir" && pnpm install)
}

main() {
  local expected_dir
  expected_dir="$(get_pacto_gov_dir)"

  # Normalize to an absolute path only if the parent directory already exists.
  local parent
  parent="$(dirname "$expected_dir")"
  if [ -d "$parent" ]; then
    expected_dir="$(cd "$parent" && pwd)/$(basename "$expected_dir")"
  fi

  if is_valid_pacto_gov "$expected_dir"; then
    log "pacto-gov is present at $expected_dir"
  else
    # Fallback: the setup scripts clone into ~/src/covenant-gov by default.
    local fallback_dir
    fallback_dir="$(expand_path "$HOME/src/covenant-gov/pacto-gov")"

    if [ "$expected_dir" != "$fallback_dir" ] && is_valid_pacto_gov "$fallback_dir"; then
      echo
      warn "Found pacto-gov at the setup-script fallback location: $fallback_dir"
      if prompt "Create a symlink so the dev environment uses it (symlink $expected_dir -> $fallback_dir)"; then
        mkdir -p "$(dirname "$expected_dir")"
        if [ -e "$expected_dir" ] || [ -L "$expected_dir" ]; then
          if [ -d "$expected_dir" ] && [ -z "$(ls -A "$expected_dir" 2>/dev/null)" ]; then
            rmdir "$expected_dir"
          else
            local backup
            backup="$expected_dir.bak.$(date +%s)"
            warn "Moving existing $expected_dir to $backup"
            mv "$expected_dir" "$backup"
          fi
        fi
        ln -s "$fallback_dir" "$expected_dir"
        log "Created symlink: $expected_dir -> $fallback_dir"
      else
        clone_pacto_gov "$expected_dir"
      fi
    else
      clone_pacto_gov "$expected_dir"
    fi

    if ! is_valid_pacto_gov "$expected_dir"; then
      err "pacto-gov is still not available at $expected_dir after setup."
      exit 1
    fi
  fi

  ensure_pacto_gov_deps "$expected_dir"

  log "pacto-gov is ready at $expected_dir"
}

main
