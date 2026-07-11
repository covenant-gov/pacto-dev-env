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

# Homebrew can be installed in /home/linuxbrew/.linuxbrew (passwordless sudo) or
# $HOME/.linuxbrew (no sudo). Source whichever is present so that brew-installed
# tools are immediately available in the current shell.
eval_brew_shellenv() {
  if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" 2>/dev/null || true
  elif [[ -x "$HOME/.linuxbrew/bin/brew" ]]; then
    eval "$($HOME/.linuxbrew/bin/brew shellenv)" 2>/dev/null || true
  fi
}

run_privileged() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    err "This step needs root privileges, but neither root nor sudo is available."
    exit 1
  fi
}

apt_pkg_installed() {
  dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -q "^install ok installed$"
}

append_if_missing() {
  local file="$1"
  local line="$2"
  if [[ -f "$file" ]] && grep -Fxq "$line" "$file" 2>/dev/null; then
    return 0
  fi
  echo "$line" >> "$file"
}

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------

install_system_packages() {
  log "Updating apt package lists..."
  run_privileged apt-get update

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
    # Network debugging tools
    socat
    jq
    netcat-openbsd
    # Local TLS certificate generation
    mkcert
    libnss3-tools
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
    DEBIAN_FRONTEND=noninteractive run_privileged apt-get install -y --no-install-recommends "${missing[@]}"
  else
    log "All required system packages already installed."
  fi
}

# ---------------------------------------------------------------------------
# Docker + Docker Compose
# ---------------------------------------------------------------------------

install_docker() {
  if command_exists docker && { command_exists "docker compose" 2>/dev/null || docker compose version >/dev/null 2>&1; }; then
    log "Docker and Docker Compose already installed: $(docker --version), $(docker compose version)"
    return 0
  fi

  log "Installing Docker Engine and Docker Compose plugin..."
  run_privileged install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    run_privileged bash -c "curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc"
    run_privileged chmod a+r /etc/apt/keyrings/docker.asc
  fi

  local arch
  arch="$(dpkg --print-architecture)"
  local codename
  codename="$(lsb_release -cs 2>/dev/null || echo "noble")"
  local repo_line="deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable"

  if ! run_privileged grep -Fxq "$repo_line" /etc/apt/sources.list.d/docker.list 2>/dev/null; then
    run_privileged bash -c "echo '$repo_line' > /etc/apt/sources.list.d/docker.list"
  fi

  run_privileged apt-get update
  DEBIAN_FRONTEND=noninteractive run_privileged apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Ensure the calling user can use Docker without sudo on next login.
  local target_user="${SUDO_USER:-${USER:-$(logname 2>/dev/null || whoami)}}"
  if [[ -n "$target_user" && "$target_user" != "root" ]]; then
    run_privileged usermod -aG docker "$target_user" || true
    log "Added $target_user to the docker group. Log out and back in for this to take effect."
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


install_websocat() {
  if command_exists websocat; then
    log "websocat already installed: $(websocat --version | head -1)"
    return 0
  fi

  # Prefer Homebrew on both macOS and Linux; the Linux setup script installs
  # Homebrew before this step. Fall back to a direct GitHub release download
  # if Homebrew is unavailable or the install fails.
  if command_exists brew || install_brew; then
    eval_brew_shellenv
    log "Installing websocat via Homebrew..."
    if brew install websocat; then
      log "websocat installed: $(websocat --version | head -1)"
      return 0
    fi
    warn "Homebrew install of websocat failed; falling back to direct download."
  fi

  log "Installing websocat from GitHub release..."
  local asset
  case "$(uname -m)" in
    x86_64) asset="websocat.x86_64-unknown-linux-musl" ;;
    aarch64|arm64) asset="websocat_max.aarch64-unknown-linux-musl" ;;
    *) err "Unsupported architecture: $(uname -m)"; return 1 ;;
  esac
  local version="1.14.0"
  local dest="$HOME/.cargo/bin/websocat"
  mkdir -p "$HOME/.cargo/bin"
  curl -fsSL "https://github.com/vi/websocat/releases/download/v${version}/${asset}" -o "$dest"
  chmod +x "$dest"
  log "websocat installed: $("$dest" --version | head -1)"
}

install_nak() {
  if command_exists nak; then
    log "nak already installed: $(nak --version | head -1)"
    return 0
  fi

  log "Installing nak from GitHub release..."
  local version="0.20.0"
  local arch
  case "$(uname -m)" in
    x86_64) arch="linux-amd64" ;;
    aarch64|arm64) arch="linux-arm64" ;;
    *) err "Unsupported architecture: $(uname -m)"; return 1 ;;
  esac
  local asset="nak-v${version}-${arch}"
  local url="https://github.com/fiatjaf/nak/releases/download/v${version}/${asset}"
  local checksum
  case "$arch" in
    linux-amd64) checksum="c92c30eb04fb5519cb385f9b5ad10248c961792c936c7a333ef0e895ef5869b9" ;;
    linux-arm64) checksum="0d51103d73dffd30f3cf5d5e2a5d2349b62aa570760bb1140233beab40a46ca9" ;;
  esac

  local tmpfile
  tmpfile="$(mktemp)"
  curl -fsSL "$url" -o "$tmpfile"
  echo "${checksum}  ${tmpfile}" | sha256sum -c - >/dev/null 2>&1
  run_privileged install -m 0755 "$tmpfile" /usr/local/bin/nak
  rm -f "$tmpfile"
  log "nak installed: $(nak --version | head -1)"
}



install_node() {
  if command_exists node; then
    local node_version
    node_version="$(node --version | sed 's/^v//')"
    local major_version
    major_version="$(echo "$node_version" | cut -d. -f1)"
    if [[ "$major_version" -ge 24 ]]; then
      log "Node.js already installed: v${node_version}"
      return 0
    else
      warn "Node.js v${node_version} is too old; installing Node 24..."
    fi
  fi

  log "Installing Node.js 24 from NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_24.x | run_privileged bash -
  DEBIAN_FRONTEND=noninteractive run_privileged apt-get install -y --no-install-recommends nodejs
}

install_pnpm() {
  if command_exists pnpm; then
    log "pnpm already installed: $(pnpm --version)"
    return 0
  fi

  # Corepack needs to write to /usr/bin when Node.js is installed via Debian
  # packages, so run it through sudo only when not root.
  log "Enabling pnpm via Corepack..."
  run_privileged corepack enable
  run_privileged corepack prepare pnpm@latest --activate
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
    return 0
  fi

  if [[ "${PACTO_SKIP_AZTEC_CLI:-}" == "1" ]]; then
    log "Skipping Aztec sandbox version manager install (PACTO_SKIP_AZTEC_CLI=1)."
    return 0
  fi

  log "Installing Aztec sandbox version manager..."
  /bin/bash -c "$(curl -fsSL 'https://raw.githubusercontent.com/AztecProtocol/sandbox-version-manager/master/install.sh')" || warn "Aztec sandbox version manager install failed; continuing."
}

# ---------------------------------------------------------------------------
# Homebrew + GitHub CLI
# ---------------------------------------------------------------------------

install_brew() {
  if command_exists brew; then
    log "Homebrew already installed: $(brew --version | head -1)"
    eval_brew_shellenv
    return 0
  fi

  log "Installing Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval_brew_shellenv
}

install_gh_cli() {
  eval_brew_shellenv

  if command_exists gh; then
    log "GitHub CLI already installed: $(gh --version | head -1)"
    return 0
  fi

  log "Installing GitHub CLI via Homebrew..."
  brew install gh
}

install_shellcheck() {
  eval_brew_shellenv

  if command_exists shellcheck; then
    log "ShellCheck already installed: $(shellcheck --version | head -1)"
    return 0
  fi

  log "Installing ShellCheck via Homebrew..."
  brew install shellcheck
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
  append_if_missing "$shell_rc" 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv 2>/dev/null || $HOME/.linuxbrew/bin/brew shellenv 2>/dev/null || true)"'
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
  local base_dir="${1:-}"

  # If no directory was supplied as an argument, ask the user.
  if [[ -z "$base_dir" ]]; then
    if [[ "${PACTO_CLONE_REPOS:-}" == "skip" ]]; then
      base_dir="$HOME/src/covenant-gov"
    else
      echo
      read -r -p "Where should the Pacto ecosystem repos be cloned? [${HOME}/src/covenant-gov]: " base_dir
      base_dir="${base_dir:-$HOME/src/covenant-gov}"
    fi
  fi

  # Expand ~ and resolve to absolute path for display.
  base_dir="${base_dir/#\~/$HOME}"

  local all_repos=(
    "pacto-app:desktop client, most users need this"
    "pacto-gov:Solidity governance contracts"
    "pacto-squad-sponsor:gas fee sponsorship contract"
    "pacto-aztec:Aztec privacy layer"
    "nostr-k-derivs:Nostr-to-chain key derivation"
    "delegated-security-manager:Hats-based security module"
    "pacto-download:download site"
  )

  echo
  echo "Toggle repositories on/off by number, then press Enter to clone."
  echo "Enter 'all' to select everything, 'none' to skip cloning, or numbers"
  echo "separated by spaces to toggle each repo (e.g. '1 2 4')."
  echo

  # Default selection: only pacto-app is selected.
  local selected=(1 0 0 0 0 0 0)

  local idx name desc
  for idx in "${!all_repos[@]}"; do
    name="${all_repos[$idx]%%:*}"
    desc="${all_repos[$idx]#*:}"
    if [[ "${selected[$idx]}" -eq 1 ]]; then
      echo "  [$((idx+1))] [X] $name - $desc"
    else
      echo "  [$((idx+1))] [ ] $name - $desc"
    fi
  done
  echo

  # Respect a non-interactive CI default: if PACTO_CLONE_REPOS=skip, skip cloning.
  local selection
  if [[ "${PACTO_CLONE_REPOS:-}" == "skip" ]]; then
    selection="none"
  else
    read -r -p "Selection [1]: " selection
    selection="${selection:-1}"
  fi

  # Handle special keywords.
  if [[ "$selection" =~ ^[[:space:]]*all[[:space:]]*$ ]]; then
    selected=(1 1 1 1 1 1 1)
  elif [[ "$selection" =~ ^[[:space:]]*none[[:space:]]*$ ]]; then
    selected=(0 0 0 0 0 0 0)
  else
    # Treat each entered number as a toggle.
    for n in $selection; do
      if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#all_repos[@]} )); then
        selected[$((n-1))]=$((1 - selected[$((n-1))]))
      else
        warn "Ignoring invalid selection: $n"
      fi
    done
  fi

  local repos=()
  for idx in "${!all_repos[@]}"; do
    if [[ "${selected[$idx]}" -eq 1 ]]; then
      repos+=("${all_repos[$idx]%%:*}")
    fi
  done

  echo
  echo "Will clone:"
  if [[ ${#repos[@]} -eq 0 ]]; then
    echo "  (none)"
  else
    for repo in "${repos[@]}"; do
      echo "  - $repo"
    done
  fi

  # Respect a non-interactive CI default: auto-confirm if PACTO_CLONE_REPOS is set.
  local confirm
  if [[ -n "${PACTO_CLONE_REPOS:-}" ]]; then
    confirm="Y"
  else
    read -r -p "Continue? [Y/n]: " confirm
    confirm="${confirm:-Y}"
  fi

  if [[ ! "$confirm" =~ ^[Yy] ]]; then
    warn "Clone step cancelled by user."
    return 0
  fi

  if [[ ${#repos[@]} -eq 0 ]]; then
    warn "No repositories selected; skipping clone step."
    return 0
  fi

  log "Cloning selected repositories into $base_dir..."
  mkdir -p "$base_dir"

  for repo in "${repos[@]}"; do
    if [[ ! -d "$base_dir/$repo" ]]; then
      git clone "https://github.com/covenant-gov/$repo.git" "$base_dir/$repo"
    else
      warn "$repo already cloned; skipping."
    fi
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

verify_install() {
  log "Verifying installed tools..."

  # Cargo/Foundry/Aztec may not be on PATH until a new shell; force them for this function.
  export PATH="$HOME/.cargo/bin:$HOME/.foundry/bin:$HOME/.aztec/bin:$PATH"

  # Homebrew-installed tools may not be on PATH yet in the current shell.
  eval_brew_shellenv

  docker --version
  docker compose version
  rustc --version
  cargo --version
  node --version
  pnpm --version
  forge --version
  anvil --version
  cast --version
  jq --version
  socat -V | head -1
  websocat --version | head -1
  nak --version | head -1
  shellcheck --version | head -1
  if command_exists aztec-sandbox; then
    aztec-sandbox --version
  else
    warn "aztec-sandbox binary not on PATH yet — open a new shell."
  fi
}


main() {

  if [[ "$EUID" -eq 0 ]] && [[ -z "${SUDO_USER:-}" ]]; then
    warn "Running as root. The script will install tools for root, not for your desktop user."
    warn "Consider running as a normal user so the script can use sudo only when needed."
  fi

  if [[ "$EUID" -ne 0 ]] && ! command_exists sudo; then
    err "This script needs sudo for installing system packages, but sudo is not installed."
    err "Install sudo or run the script as root."
    exit 1
  fi

  install_system_packages
  install_docker
  install_rust
  install_websocat
  install_nak
  install_node
  install_pnpm
  install_foundry
  install_aztec_cli
  install_brew
  install_gh_cli
  install_shellcheck
  configure_shell
  clone_repos "${1:-}"
  verify_install

  log "Setup complete. Open a new shell (or run \`source ~/.bashrc\`) to pick up environment changes."
  log "Trust the local TLS certificate authority once before starting services:"
  log "  mkcert -install"
  log "Then start the dev services:"
  log "  cd pacto-dev-env"
  log "  make up"
  log "Next steps for app development:"
  log "  cd <your-clone-dir>/pacto-app"
  log "  pnpm install"
  log "  pnpm run tauri:dev"
}

main "$@"
