#!/usr/bin/env bash
set -euo pipefail

# setup-macos-arm64.sh
# One-shot install script for Pacto ecosystem development on Apple Silicon Macs.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; }

require_rosetta() {
  if ! /usr/bin/pgrep -q oahd; then
    warn "Rosetta 2 is not installed. Some Docker/x86 tools need it."
    read -rp "Install Rosetta 2 now? [Y/n] " ans
    if [[ "$ans" =~ ^[Yy]?$ ]]; then
      softwareupdate --install-rosetta --agree-to-license
    fi
  else
    log "Rosetta 2 already installed."
  fi
}

install_homebrew() {
  if ! command -v brew >/dev/null 2>&1; then
    log "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  # Load Homebrew into this non-login shell
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

install_base_tools() {
  log "Updating Homebrew and installing base tools..."
  brew update
  brew install git curl wget jq coreutils pkg-config cmake llvm rustup node pnpm

  # Docker Desktop must be installed manually or via Homebrew Cask
  if ! command -v docker >/dev/null 2>&1; then
    warn "Docker CLI not found. Installing Docker Desktop via Homebrew Cask..."
    brew install --cask docker
    warn "Please open Docker Desktop and wait for it to finish starting."
    read -rp "Press Enter once Docker Desktop is running..."
  fi
}

install_rust() {
  # Homebrew's rustup formula installs rustup directly; there is no rustup-init binary.
  # On first install the rustup wrappers may not be linked into /opt/homebrew/bin.
  if ! command -v rustup >/dev/null 2>&1; then
    log "rustup binary not on PATH — checking Homebrew..."
    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi

  if ! command -v rustup >/dev/null 2>&1; then
    err "rustup is not installed. The Homebrew 'rustup' formula should have provided it."
    return 1
  fi

  log "Installing / updating Rust toolchain via rustup..."
  rustup default stable

  # Ensure rustup's tool wrappers are on PATH for the rest of this script.
  # Homebrew recommends /opt/homebrew/opt/rustup/bin; also support /usr/local.
  if [[ -d /opt/homebrew/opt/rustup/bin ]]; then
    export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
  elif [[ -d /usr/local/opt/rustup/bin ]]; then
    export PATH="/usr/local/opt/rustup/bin:$PATH"
  fi
  if [[ -f "$HOME/.cargo/env" ]]; then
    source "$HOME/.cargo/env"
  fi

  # If Homebrew did not link rustup's wrappers, link them now.
  if ! command -v rustc >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      log "Linking rustup wrappers into Homebrew bin..."
      brew link rustup && export PATH="$(brew --prefix)/bin:$PATH"
    fi
  fi

  rustup target add x86_64-unknown-linux-gnu 2>/dev/null || true
  rustup target add aarch64-apple-darwin
  rustup component add rustfmt clippy

  if ! command -v rustc >/dev/null 2>&1; then
    err "rustc is still not on PATH after rustup install/link. Try opening a new shell."
    return 1
  fi
  log "Rust installed: $(rustc --version)"
}

install_foundry() {
  if ! command -v forge >/dev/null 2>&1; then
    log "Installing Foundry (forge, cast, anvil, chisel)..."
    curl -L https://foundry.paradigm.xyz | bash
    export PATH="$HOME/.foundry/bin:$PATH"
    foundryup
  else
    log "Foundry already installed: $(forge --version)"
  fi
}

install_aztec_cli() {
  if ! command -v aztec-sandbox >/dev/null 2>&1; then
    log "Installing Aztec sandbox version manager..."
    /bin/bash -c "$(curl -fsSL 'https://raw.githubusercontent.com/AztecProtocol/sandbox-version-manager/master/install.sh')"
  else
    log "Aztec sandbox version manager already installed."
  fi
}

configure_shell() {
  local shell_rc="$HOME/.zshrc"
  [[ "$SHELL" == */bash ]] && shell_rc="$HOME/.bashrc"

  log "Updating PATH in $shell_rc..."
  {
    echo ''
    echo '# Pacto dev environment'
    echo 'export PATH="$HOME/.cargo/bin:$HOME/.foundry/bin:$PATH"'
    echo 'export PKG_CONFIG_PATH="/opt/homebrew/opt/openssl/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:$PKG_CONFIG_PATH"'
    echo 'export CC="/usr/bin/clang"'
    echo 'export CXX="/usr/bin/clang++"'
  } >> "$shell_rc"
}

clone_repos() {
  local base_dir="${1:-$HOME/src/covenant-gov}"
  log "Cloning Pacto ecosystem repositories into $base_dir..."
  mkdir -p "$base_dir"
  cd "$base_dir"

  for repo in pacto-app pacto-gov pacto-squad-sponsor pacto-aztec \
              nostr-k-derivs delegated-security-manager pacto-download; do
    if [[ ! -d "$repo" ]]; then
      git clone "https://github.com/covenant-gov/$repo.git"
    else
      warn "$repo already cloned; skipping."
    fi
  done
}

verify_install() {
  log "Verifying installed tools..."

  # Cargo/Foundry/Aztec may not be on PATH until a new shell; force them for this function.
  export PATH="$HOME/.cargo/bin:$HOME/.foundry/bin:$HOME/.aztec/bin:$PATH"

  docker --version
  docker compose version
  rustc --version
  cargo --version
  node --version
  pnpm --version
  forge --version
  anvil --version
  cast --version
  if command -v aztec-sandbox >/dev/null 2>&1; then
    aztec-sandbox --version
  else
    warn "aztec-sandbox binary not on PATH yet — open a new shell."
  fi
}

main() {
  log "Starting Pacto dev setup for macOS Apple Silicon..."
  require_rosetta
  install_homebrew
  install_base_tools
  install_rust
  install_foundry
  install_aztec_cli
  configure_shell
  clone_repos "${1:-$HOME/src/covenant-gov}"
  verify_install
  log "Setup complete. Open a new shell to pick up environment changes."
  log "Next steps:"
  log "  cd $HOME/src/covenant-gov/pacto-app"
  log "  pnpm install"
  log "  pnpm tauri dev"
}

main "$@"
