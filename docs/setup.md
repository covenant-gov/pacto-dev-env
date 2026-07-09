# Setup guide

How to prepare your machine for Pacto development. Most people should use the one-shot setup scripts; the manual steps below are for custom environments or when you need to understand what the scripts install.

## One-shot host setup

**macOS (Apple Silicon):**

```bash
bash ./setup-macos-arm64.sh
```

**Ubuntu 24.04/24.10/26.04 LTS:**

```bash
bash ./setup-ubuntu-lts.sh
```

Both scripts are idempotent. The Ubuntu script installs Docker, Rust, Node 24, pnpm, Foundry, the Aztec sandbox version manager, and Tauri system dependencies. It prompts for `sudo` only when a step actually needs elevated privileges.

Open a new shell after the script finishes so PATH changes take effect.

## Manual prerequisites

If you prefer not to use the setup scripts, install these first.

### Docker and Docker Compose

Docker is required because every local service is containerized.

```bash
docker --version
docker compose version
```

Recommended minimum resources:

| Service | RAM |
|---------|-----|
| Pacto build + relay | 4 GB |
| Aztec sandbox | 8 GB |
| Everything together | 12–16 GB |

### Rust

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
rustc --version
cargo --version
```

### Node.js / pnpm

Pacto uses pnpm. Node 24 is recommended:

```bash
corepack enable
corepack prepare pnpm@latest --activate
pnpm --version
```

### Foundry (for EVM contracts)

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
anvil --version
forge --version
cast --version
```

### System dependencies

**Ubuntu/Debian (Tauri):**

```bash
sudo apt update
sudo apt install -y \
  build-essential cmake clang libclang-dev curl wget file git pkg-config \
  libvulkan-dev libwebkit2gtk-4.1-dev libxdo-dev libssl-dev \
  libayatana-appindicator3-dev librsvg2-dev libasound2-dev \
  mkcert libnss3-tools
```

**macOS / Apple Silicon:**

```bash
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then install the toolchain:

```bash
brew install docker rustup node@24 pnpm foundry cmake llvm pkg-config openssl@3 git wget mkcert
echo 'export PATH="$(brew --prefix llvm)/bin:$PATH"' >> ~/.zshrc
echo 'export LIBCLANG_PATH="$(brew --prefix llvm)/lib"' >> ~/.zshrc
echo 'export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig:$PKG_CONFIG_PATH"' >> ~/.zshrc
source ~/.zshrc
```

**Windows:** use WSL2 with the Ubuntu instructions above. Tauri builds on native Windows are supported but slower.

## Clone the ecosystem

Decide where you want the workspace and which repositories you need. Most people only clone the project they are actively working on; the shared services in `pacto-dev-env` run independently.

| If you are working on... | Clone this repo |
|--------------------------|-----------------|
| The desktop app | `pacto-app` |
| Solidity governance contracts | `pacto-gov` |
| Gas-sponsorship contract | `pacto-squad-sponsor` |
| Aztec privacy layer | `pacto-aztec` |
| Nostr key derivations | `nostr-k-derivs` |
| Security module | `delegated-security-manager` |
| Download site / landing page | `pacto-download` |

For example, to work only on `pacto-app` under `~/src/covenant-gov`:

```bash
mkdir -p ~/src/covenant-gov
cd ~/src/covenant-gov

git clone https://github.com/covenant-gov/pacto-app.git
```

If you want everything, clone all of them:

```bash
mkdir -p ~/src/covenant-gov
cd ~/src/covenant-gov

git clone https://github.com/covenant-gov/pacto-app.git
git clone https://github.com/covenant-gov/pacto-gov.git
git clone https://github.com/covenant-gov/pacto-squad-sponsor.git
git clone https://github.com/covenant-gov/pacto-aztec.git
git clone https://github.com/covenant-gov/nostr-k-derivs.git
git clone https://github.com/covenant-gov/delegated-security-manager.git
git clone https://github.com/covenant-gov/pacto-download.git
```

> The setup scripts can clone the ecosystem for you, but they default to `~/src/covenant-gov` and clone all repositories. If you prefer a different directory or a subset of repos, run the manual `git clone` steps instead.

## Security notes for local development

- All local services bind to `localhost` only by default. Do not expose Anvil, the relay, or the NIP-46 bunker to the public internet.
- Never commit private keys or bunker URIs to Git.
- `pacto-bot-api.toml` is ignored by Git and created with mode `0o600` so signing material is not accidentally committed.
