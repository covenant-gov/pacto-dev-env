# Getting Started — Pacto Ecosystem Development

This guide gets you from zero to a working local dev environment for Pacto and its directly-related apps, libraries, and dependencies.

This is the single onboarding document: quick-start commands up front, full explanations and per-project workflows below.

For a unified architecture and operations reference, see [`ARCHITECTURE.md`](ARCHITECTURE.md).

---

## What this covers

This repo (`pacto-dev-env`) provides the shared local services that all Covenant Gov projects need:

- Nostr relay on `ws://localhost:7000` and `wss://localhost:7001` (TLS sidecar)
- Anvil EVM testnet on `http://localhost:8545`
- Aztec sandbox on `http://localhost:8080` (opt-in profile)
- NIP-46 bunker on `http://127.0.0.1:3001` (opt-in profile)

You then work on the individual projects that consume these services:

- `pacto-app` — Rust/Tauri desktop client
- `pacto-gov` — Solidity governance contracts ("Nave Pirata")
- `pacto-squad-sponsor` — gas-sponsorship contract
- `delegated-security-manager` — Hats-based security module
- `pacto-aztec` — Noir/TypeScript Aztec privacy layer
- `nostr-k-derivs` — Nostr-key-to-chain-address derivation

---

## Quick start (Docker)

### 1. One-shot host setup

**macOS (Apple Silicon):**

```bash
bash ./setup-macos-arm64.sh
```

**Ubuntu 24.04/24.10/26.04 LTS:**

```bash
bash ./setup-ubuntu-lts.sh
```

Both scripts are idempotent — re-running skips already-installed tools. The Ubuntu script installs Docker, Rust, Node 24, pnpm, Foundry, the Aztec sandbox version manager, and Tauri system dependencies. It prompts for `sudo` only when a step actually needs elevated privileges (for example, installing system packages).

### 2. Start the local services

The `pacto-bot-api` daemon needs a `pacto-bot-api.toml` config file. `make up` will generate a minimal one automatically if it is missing.

To start with a default bot identity, set both `PACTO_BOT_NPUB` and `PACTO_BOT_NSEC` in your environment or `.env` file before running `make up`:

```bash
# .env
PACTO_BOT_NPUB=npub1...
PACTO_BOT_NSEC=nsec1...
```

Without `PACTO_BOT_NSEC`, the daemon starts with no bots. You can add bot identities later by appending to `pacto-bot-api.toml`:

```bash
pacto-bot-admin new bosun --backend nsec --relays ws://localhost:7000 >> pacto-bot-api.toml
docker compose restart pacto-bot-api
```

`pacto-bot-api.toml` is ignored by Git and created with mode `0o600` so signing material is not accidentally committed.

Start the stack:

```bash
cd pacto-dev-env
make up          # or: docker compose up -d --build
make up-all      # everything including bunker, aztec, and seed
```

`make up` starts the default stack:

- Nostr relay on `ws://localhost:7000` and `wss://localhost:7001` (TLS sidecar)
- Anvil EVM testnet on `http://localhost:8545`
- `pacto-bot-api` daemon, listening on a Unix socket inside the `pacto-bot-api-data` volume

The `wss://localhost:7001` endpoint is served by a Caddy sidecar that terminates TLS and proxies plain `ws://` to the relay. By default it uses a Caddy-generated self-signed certificate, so clients must skip certificate verification (e.g. `websocat -k`) or run `scripts/generate-local-certs.sh` to switch to a locally-trusted `mkcert` certificate.

The `nostr-relay`, `aztec-sandbox`, and `nip46-bunker` services are pulled from prebuilt GHCR images. `anvil` is built locally from `docker/anvil.Dockerfile` because the GHCR image is not yet public, so the first run may take a few minutes while Foundry compiles.

`make up-all` is equivalent to `docker compose --profile full up -d --build`; it starts the default stack plus the Aztec sandbox, the NIP-46 bunker, and the optional Pacto governance seeder.

> Aztec is heavy. Allocate at least 8 GB of RAM to Docker and expect a 2–3 minute startup while it deploys L1 contracts to Anvil. The `seed` service deploys the Pacto governance contracts to Anvil when the `full` profile is used.

### Optional profiles

| Profile | Services added |
|---|---|
| `aztec` | `aztec-sandbox` on `http://localhost:8080` (admin `http://localhost:8880`) |
| `bunker` | `nip46-bunker` on `http://127.0.0.1:3001` |
| `seed` | One-shot deploy of Pacto governance contracts to Anvil; writes artifacts to `./data/deployments/31337/` |
| `full` | `aztec` + `bunker` + `seed` |
| `debug` | Interactive sidecar with `socat`, `websocat`, `curl`, `jq`, `nc`, `psql`, `redis-cli` |

```bash
# Aztec sandbox
docker compose --profile aztec up -d --build

# NIP-46 bunker
docker compose --profile bunker up -d --build

# Everything optional together
docker compose --profile full up -d --build

# Debug sidecar
docker compose --profile debug up -d --build
```

### Seed governance contracts to Anvil

The `seed` profile is a one-shot service that deploys the Pacto governance
contracts from the sibling `pacto-gov` repository to the local Anvil testnet
(chain ID 31337). It runs `forge script script/Deploy.sol` using the default
Anvil private key and writes deployment artifacts to
`./data/deployments/31337/`.

```bash
# Deploy once (the `seed` service exits cleanly after deployment)
make seed
# or equivalently:
# docker compose --profile seed run --rm seed
```

`make seed` and `make up-all` automatically ensure the `pacto-gov` sibling
repository is present at `../pacto-gov` (configurable with `PACTO_GOV_DIR` in
your environment) and that its Node dependencies are installed. If either is
missing, you will be prompted to clone or install; use `YES=1` to proceed
automatically without prompting (e.g. `make up-all YES=1`).

After the deployment finishes, the full-system artifact is available at:

```bash
cat ./data/deployments/31337/full-system.json | jq .
```

Useful fields:

| Field | Contract |
|---|---|
| `navePirataRegistry` | `NavePirataRegistry` |
| `navePirataFactory` | `NavePirataFactory` |
| `roleHatClonesFactory` | `RoleHatClonesFactory` |
| `hats` | Hats Protocol v1 |

The `seed` service is also included in the `full` profile, so `make up-all`
deploys the contracts automatically while starting the optional services.

`make seed` is idempotent: if `full-system.json` already exists, the service
prints the existing artifact path and exits. Set `FORCE_SEED=1` to re-deploy,
or run `make reset` to clear all state and start over.

Before using `bunker` or `full`, generate real secrets in `.env`. Copy `.env.example` and override the placeholder values:

```bash
cp .env.example .env
# edit .env with secure values
```

`make pull` fetches the latest prebuilt GHCR images without restarting anything.

### Verify the default stack

Run the automated health check:

```bash
make check
```

`make check` first verifies that the host has the required tools installed (Docker, Rust, Foundry, pnpm, jq, socat, websocat, etc.). If anything is missing, it prints the remediation step for your platform (run `setup-macos-arm64.sh` or `setup-ubuntu-lts.sh`). It then verifies that the running Docker Compose services are healthy and reachable.

To check only the host environment:

```bash
make check-env
```

![Self-documenting Make targets and healthy stack output](docs/assets/make-help-check.png)

Or check each service manually:

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cast block-number --rpc-url http://localhost:8545
curl -s http://localhost:7000 | head -5
websocat -k wss://localhost:7001 -1
docker compose exec pacto-bot-api test -S /var/lib/pacto-bot-api/pacto-bot-api.sock && echo "daemon socket ready"
```

### Shared network

`docker-compose.yml` declares a bridge network named `pacto`. Sibling application composes can attach to it as an external network so their containers reach the dev-env services by Docker service name instead of duplicating them:

```yaml
services:
  my-app:
    networks:
      - pacto

networks:
  pacto:
    external: true
```

Inside an attached container, use service names rather than `localhost`:

- `http://anvil:8545` for the EVM RPC
- `ws://nostr-relay:8080` for the Nostr relay
- `wss://caddy:8443` for the Nostr relay over TLS from inside the Docker network
- `http://aztec-sandbox:8080` for Aztec RPC
- `http://nip46-bunker:3000` for the NIP-46 bunker

> Host-facing ports are bound to `127.0.0.1` by default, so services are only reachable from the local machine unless you explicitly change the bind address.

---

## Manual prerequisites

If you prefer not to use the setup scripts, install these first.

### Docker and Docker Compose

Docker is required because every local service is containerized. Install Docker Engine or Docker Desktop, then verify:

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
  libayatana-appindicator3-dev librsvg2-dev libasound2-dev
```

**macOS / Apple Silicon:**

```bash
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then install the tool chain:

```bash
brew install docker rustup node@24 pnpm foundry cmake llvm pkg-config openssl@3 git wget
echo 'export PATH="$(brew --prefix llvm)/bin:$PATH"' >> ~/.zshrc
echo 'export LIBCLANG_PATH="$(brew --prefix llvm)/lib"' >> ~/.zshrc
echo 'export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig:$PKG_CONFIG_PATH"' >> ~/.zshrc
source ~/.zshrc
```

**Windows:** use WSL2 with the Ubuntu instructions above. Tauri builds on native Windows are supported but slower.

---

## Clone the ecosystem

Before cloning, decide:

1. **Where do you want the workspace?** The examples below use `~/src/covenant-gov`, but you can choose any directory.
2. **Which repositories do you need?** Most people only need the project they are actively working on. The shared services in `pacto-dev-env` run independently.

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

> The one-shot setup scripts can do this for you, but they default to `~/src/covenant-gov` and clone all repositories. If you prefer a different directory or a subset of repos, run the manual `git clone` steps instead.

---

## Project workflows

All workflows assume the default Docker services are running:

```bash
cd pacto-dev-env
make up
```

### Build and run `pacto-app`

```bash
cd ~/src/covenant-gov/pacto-app
pnpm install
pnpm run tauri:dev
```

First build downloads and compiles many Rust crates — expect several minutes.

To run just the frontend in a browser:

```bash
pnpm dev
```

#### Connect `pacto-app` to the local EVM chain

1. Start the dev services: `cd pacto-dev-env && make up`.
2. In `pacto-app`, open **Settings → Wallet / Network**.
3. Add a custom EVM network:
   - Name: `Pacto Local`
   - RPC URL: `http://localhost:8545`
   - Chain ID: `31337`
   - Currency symbol: `ETH`
4. Import the default Anvil private key for a test account:
   - Account #0 key: `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`
   - **Never use this key outside of local development.**

#### Common `pacto-app` build fixes

| Error | Fix |
|-------|-----|
| `webkit2gtk-4.1` not found | `sudo apt install libwebkit2gtk-4.1-dev` |
| `openssl-sys` build fails | `sudo apt install libssl-dev pkg-config` |
| `bindgen` errors | `sudo apt install clang libclang-dev` |
| Vulkan errors on Linux | `sudo apt install libvulkan-dev` |
| macOS `cc` / linker not found | `xcode-select --install` |
| macOS OpenSSL errors | `brew install openssl@3 pkg-config` and export `PKG_CONFIG_PATH` |

### Work on Solidity contracts

```bash
cd ~/src/covenant-gov/pacto-gov
forge install
forge build
forge test
```

Deploy against the local Anvil node:

```bash
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

Use the same RPC and key for `pacto-squad-sponsor` and `delegated-security-manager`.

#### Make `pacto-app` use freshly deployed contracts

After running the deploy script, note the printed contract addresses. Then:

1. Find the contract-address config file in `pacto-app` (often under `src-tauri/src/evm/contracts/` or `.env.local`).
2. Update the fields for `PactoGov`, `SquadSponsor`, or `DelegatedSecurityManager` to the addresses from the deploy output.
3. Restart `pnpm run tauri:dev` if the values are read only at Tauri startup.

If the app does not expose a config file, search the Rust source for the current contract address constants and replace them temporarily for local testing — but **do not commit hardcoded local addresses**.

### Work on `pacto-aztec`

Start the Aztec profile:

```bash
cd pacto-dev-env
make up-all          # or: docker compose --profile aztec up -d --build
```

Then follow the Aztec project's own README:

```bash
cd ~/src/covenant-gov/pacto-aztec
pnpm install
pnpm compile   # compiles Noir contracts
pnpm test      # runs tests against the sandbox
```

The Aztec RPC is at `http://localhost:8080`.

### Work on `nostr-k-derivs`

```bash
cd ~/src/covenant-gov/nostr-k-derivs
cargo build
cargo test
```


---

## Port and endpoint reference

| Service | URL | Docker service | Notes |
|---------|-----|----------------|-------|
| Nostr relay | `ws://localhost:7000` | `nostr-relay` | Default stack; binds to `127.0.0.1` |
| Anvil EVM | `http://localhost:8545` | `anvil` | Chain ID 31337; binds to `127.0.0.1` |
| Aztec sandbox | `http://localhost:8080` | `aztec-sandbox` | Profile `aztec`; binds to `127.0.0.1` |
| Aztec admin | `http://localhost:8880` | `aztec-sandbox` | Profile `aztec`; binds to `127.0.0.1` |
| NIP-46 bunker | `http://127.0.0.1:3001` | `nip46-bunker` | Profile `bunker`; binds to `127.0.0.1` |
| Pacto seed artifacts | `./data/deployments/31337/` | `seed` | Profile `seed`; one-shot deploy output |
| Debug sidecar | — | `debug` | Profile `debug`; `docker compose exec debug bash` |

## Recommended daily workflow

1. Start Docker services: `cd pacto-dev-env && make up`.
2. If working on Aztec, use `make up-all` or run `docker compose --profile aztec up -d --build`.
3. If working on governance contracts, run `make seed` to deploy the Pacto governance system to Anvil and read addresses from `./data/deployments/31337/full-system.json`.
4. In one terminal, run `pacto-app`: `cd pacto-app && pnpm run tauri:dev`.
5. Iterate. Re-run `cargo test`, `forge test`, or `pnpm test` as appropriate.

---

## Notes and caveats


## Debugging

Host-side debugging tools are installed by the setup scripts: `socat`, `websocat`, `jq`, `curl`, and `cast`.

Start the optional debug sidecar to inspect services from inside the container network:

```bash
docker compose --profile debug up -d --build
docker compose exec debug bash
```

Common recipes:

```bash
# Open a raw WebSocket to the Nostr relay
websocat ws://nostr-relay:8080

# Send a Nostr REQ filter (paste, then hit Enter twice)
websocat ws://nostr-relay:8080
["REQ", "debug-1", {"kinds": [1], "limit": 5}]

# Tap relay traffic between ports
socat -v TCP-LISTEN:7001,fork TCP:nostr-relay:8080

# Check Anvil RPC from inside the container network
curl -fsS -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://anvil:8545 | jq .

# Inspect bunker Postgres
psql postgresql://bunker46:bunker46@nip46-bunker-db:5432/bunker46

# Inspect bunker Redis
redis-cli -h nip46-bunker-redis ping
```

- The `anvil` image is built locally for the host architecture (arm64 on Apple Silicon, x86_64 on Linux) because the GHCR image is not yet public. The `nostr-relay`, `aztec-sandbox`, and `nip46-bunker` images are pulled from GHCR. No `platform: linux/amd64` pinning or Rosetta emulation is required.
- First `make up` will take a few minutes while `anvil` is built from source. Subsequent starts use the cached `pacto-anvil:local` image.
- If Anvil emulation is too slow on an M4 Mac, run `anvil` natively via `foundryup` instead and stop the `anvil` container.
- Aztec's sandbox is the heaviest service. Do not start it unless you are actively working on `pacto-aztec`.
- Private keys should never be committed. The `nsec` signing backend is for local testing only.

---

## Troubleshooting

### Docker containers fail to start

- Confirm Docker has enough RAM (12+ GB when running Aztec).
- Check logs: `cd pacto-dev-env && docker compose logs -f`.

### `pacto-app` cannot connect to the local relay

- Verify the relay is listening: `curl http://localhost:7000` should return a landing page or relay info.
- In Pacto settings, add `ws://localhost:7000` as a relay.


### Foundry/Anvil deployment fails

- Confirm the Anvil container is running and RPC responds:
  `cast block-number --rpc-url http://localhost:8545`.
- Use the default Anvil private key for local deployments; never commit real keys.

### Aztec sandbox is slow or OOMs

- Increase Docker memory limit to at least 8 GB, preferably 12 GB.
- Stop other containers you are not actively using.

---

## Security notes for local development

- All local services bind to `localhost` only by default. Do not expose Anvil, the relay, or the NIP-46 bunker to the public internet.
- Never commit private keys or bunker URIs to Git.
---

## Sources

- Pacto ecosystem overview: `docs/pacto_ecosystem_research.md`
- Pacto README: https://github.com/covenant-gov/pacto-app/blob/main/README.md
- build guide: https://github.com/covenant-gov/pacto-app/blob/main/docs/build/ubuntuGuide.md
- macOS guide: https://github.com/covenant-gov/pacto-app/blob/main/docs/build/macGuide.md
- Nostry hub for many projects https://github.com/aljazceru/awesome-nostr