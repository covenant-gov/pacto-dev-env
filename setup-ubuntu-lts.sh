#!/usr/bin/env bash
set -euo pipefail

# setup-ubuntu-lts.sh
# One-shot, idempotent install script for Pacto ecosystem development on Ubuntu 24.04/24.10/26.04 LTS.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Idempotency helpers
# ---------------------------------------------------------------------------

command_exists() { command -v "$1" >/dev/null 2>&1; }

apt_pkg_installed() {
  dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -q "^install ok installed$"
}

append_if_missing() {
  local file="$1"
  local line="$2"
  if [[ -f "$file" ]]; then
    grep -Fxq "$line" "$file" || echo "$line" >> "$file"
  else
    echo "$line" >> "$file"
  fi
}

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------

install_system_packages() {
  log "Updating apt package lists..."
  apt-get update

  local pkgs=(
    # Core build toolchain
    build-essential
    cmake
    clang
    libclang-dev
    curl
    wget
    file
    git
    pkg-config
    ca-certificates
    gnupg
    lsb-release
    software-properties-common
    # Tauri / desktop deps
    libvulkan-dev
    libwebkit2gtk-4.1-dev
    libxdo-dev
    libssl-dev
    libayatana-appindicator3-dev
    librsvg2-dev
    libasound2-dev
    # Docker convenience
    uidmap
  )

  local missing=()
  for pkg in "${pkgs[@]}"; do
    apt_pkg_installed "$pkg" || missing+=("$pkg")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log "Installing missing system packages: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
  else
    log "All required system packages already installed."
  fi
}

# ---------------------------------------------------------------------------
# Docker + Docker Compose
# ---------------------------------------------------------------------------

install_docker() {
  if command_exists docker && command_exists "docker compose" 2>/dev/null || docker compose version >/dev/null 2>&1; then
    log "Docker and Docker Compose already installed: $(docker --version), $(docker compose version)"
    return 0
  fi

  log "Installing Docker Engine and Docker Compose plugin..."
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  local arch="$(dpkg --print-architecture)"
  local codename="$(lsb_release -cs 2>/dev/null || echo "noble")"
  local repo_line="deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable"

  if ! grep -Fxq "$repo_line" /etc/apt/sources.list.d/docker.list 2>/dev/null; then
    echo "$repo_line" > /etc/apt/sources.list.d/docker.list
  fi

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Ensure the calling user can use Docker without sudo on next login.
  if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG docker "$SUDO_USER" || true
    log "Added $SUDO_USER to the docker group. Log out and back in for this to take effect."
  fi
}

# ---------------------------------------------------------------------------
# Rust
# ---------------------------------------------------------------------------

install_rust() {
  if command_exists rustc && command_exists cargo; then
    log "Rust already installed: $(rustc --version)"
  else
    log "Installing rustup / Rust stable..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  fi

  source "$HOME/.cargo/env" 2>/dev/null || true
  export PATH="$HOME/.cargo/bin:$PATH"

  rustup default stable >/dev/null 2>&1 || true
  rustup component add rustfmt clippy 2>/dev/null || true
  rustup target add x86_64-unknown-linux-gnu 2>/dev/null || true

  log "Rust ready: $(rustc --version)"
}

# ---------------------------------------------------------------------------
# Node.js + pnpm
# ---------------------------------------------------------------------------

install_node() {
  if command_exists node; then
    local node_version
    node_version="$(node --version | sed 's/^v//')"
    local major_version
    major_version="$(echo "$node_version" | cut -d. -f1)"
    if [[ "$major_version" -ge 20 ]]; then
      log "Node.js already installed: v${node_version}"
      return 0
    else
      warn "Node.js v${node_version} is too old; installing Node 20..."
    fi
  fi

  log "Installing Node.js 20 from NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs
}

install_pnpm() {
  if command_exists pnpm; then
    log "pnpm already installed: $(pnpm --version)"
  else
    log "Enabling pnpm via Corepack..."
    corepack enable
    corepack prepare pnpm@latest --activate
  fi
}

# ---------------------------------------------------------------------------
# Foundry
# ---------------------------------------------------------------------------

install_foundry() {
  if command_exists forge && command_exists cast && command_exists anvil; then
    log "Foundry already installed: $(forge --version)"
  else
    log "Installing Foundry..."
    curl -L https://foundry.paradigm.xyz | bash
    export PATH="$HOME/.foundry/bin:$PATH"
    foundryup
  fi
}

# ---------------------------------------------------------------------------
# Aztec CLI / sandbox version manager
# ---------------------------------------------------------------------------

install_aztec_cli() {
  if command_exists aztec-sandbox; then
    log "Aztec sandbox version manager already installed: $(aztec-sandbox --version 2>/dev/null || echo 'unknown version')"
  else
    log "Installing Aztec sandbox version manager..."
    /bin/bash -c "$(curl -fsSL 'https://raw.githubusercontent.com/AztecProtocol/sandbox-version-manager/master/install.sh')"
  fi
}

# ---------------------------------------------------------------------------
# Shell environment
# ---------------------------------------------------------------------------

configure_shell() {
  local shell_rc="$HOME/.bashrc"
  if [[ -n "${ZSH_VERSION:-}" ]] || [[ "$SHELL" == */zsh ]]; then
    shell_rc="$HOME/.zshrc"
  fi

  log "Updating PATH and env in ${shell_rc} (idempotent)..."
  touch "$shell_rc"

  append_if_missing "$shell_rc" ''
  append_if_missing "$shell_rc" '# Pacto dev environment'
  append_if_missing "$shell_rc" 'export PATH="$HOME/.cargo/bin:$HOME/.foundry/bin:$HOME/.aztec/bin:$PATH"'
  append_if_missing "$shell_rc" 'source "$HOME/.cargo/env" 2>/dev/null || true'

  if ! grep -q 'PKG_CONFIG_PATH.*openssl' "$shell_rc" 2>/dev/null; then
    echo 'export PKG_CONFIG_PATH="/usr/lib/x86_64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH"' >> "$shell_rc"
  fi
}

# ---------------------------------------------------------------------------
# Ecosystem repos
# ---------------------------------------------------------------------------

clone_repos() {
  local base_dir="${1:-$HOME/src/covenant-gov}"
  log "Cloning Pacto ecosystem repositories into $base_dir..."
  mkdir -p "$base_dir"

  for repo in pacto-app pacto-gov pacto-squad-sponsor pacto-aztec \
              nostr-k-derivs delegated-security-manager pacto-download; do
    if [[ ! -d "$base_dir/$repo" ]]; then
      git clone "https://github.com/covenant-gov/$repo.git" "$base_dir/$repo"
    else
      warn "$repo already cloned; skipping."
    fi
  done
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

verify_install() {
  log "Verifying installed tools..."

  export PATH="$HOME/.cargo/bin:$HOME/.foundry/bin:$HOME/.aztec/bin:$PATH"
  source "$HOME/.cargo/env" 2>/dev/null || true

  docker --version
  docker compose version
  rustc --version
  cargo --version
  node --version
  pnpm --version
  forge --version
  anvil --version
  cast --version
  if command_exists aztec-sandbox; then
    aztec-sandbox --version 2>/dev/null || warn "aztec-sandbox present but could not print version."
  else
    warn "aztec-sandbox binary not on PATH yet — open a new shell."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  log "Starting Pacto dev setup for Ubuntu LTS..."

  if [[ "$EUID" -ne 0 ]]; then
    err "This script must be run with sudo, e.g.:\n  sudo ./dev-setup/setup-ubuntu-lts.sh"
    exit 1
  fi

  install_system_packages
  install_docker
  install_rust
  install_node
  install_pnpm
  install_foundry
  install_aztec_cli
  configure_shell
  clone_repos "${1:-$HOME/src/covenant-gov}"
  verify_install

  log "Setup complete. Open a new shell (or run \`source ~/.bashrc\`) to pick up environment changes."
  log "Next steps:"
  log "  cd $HOME/src/covenant-gov/pacto-app"
  log "  pnpm install"
  log "  pnpm run tauri:dev"
  log ""
  log "To start the local Docker services:"
  log "  cd dev-setup"
  log "  docker compose up -d --build"
}

main "$@"
