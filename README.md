# Pacto Ecosystem Dev Setup

This directory contains everything needed to spin up a local development environment for Pacto and its directly-related apps, libraries, and dependencies.

## Files

| File | Purpose |
|------|---------|
| `relay-config.toml` | Relay configuration passed into the Nostr relay container. |
| `setup-macos-arm64.sh` | One-shot setup script for Apple Silicon Macs. |
| `setup-ubuntu-lts.sh` | One-shot setup script for Ubuntu 24.04/24.10/26.04 LTS. |
| `docker/` | Local Dockerfiles that build native arm64/amd64 images for the relay, anvil, Aztec wrapper, and NIP-46 bunker. |
## Quick start (Docker)

### 1. One-shot host setup

**macOS (Apple Silicon):**

```bash
./dev-setup/setup-macos-arm64.sh
```

**Ubuntu 24.04/24.10/26.04 LTS:**

```bash
sudo ./dev-setup/setup-ubuntu-lts.sh
```

The Ubuntu script installs Docker, Rust, Node 20, pnpm, Foundry, Aztec sandbox version manager, Tauri system dependencies, and clones the Covenant Gov repos into `~/src/covenant-gov/`. It is idempotent — re-running it skips already-installed tools.

### 2. Start the local services

```bash
cd dev-setup
mkdir -p data/relay
docker compose up -d --build
```

This builds and starts:
- Nostr relay on `ws://localhost:7000`
- Anvil EVM testnet on `http://localhost:8545`

The images are built locally from the Dockerfiles in `dev-setup/docker/`, so the first run will take several minutes. All images run natively on Apple Silicon and x86_64 Linux (no Rosetta emulation or `platform:` pinning).

### Aztec sandbox

Enable the Aztec profile when you are working on `pacto-aztec`:

```bash
docker compose --profile aztec up -d --build
```

This adds the Aztec local network on `http://localhost:8080` and admin API on `http://localhost:8880`. The Aztec container deploys its own rollup contracts to the local Anvil, so Anvil must be healthy first.

> The Aztec service is heavy. Allocate at least 8 GB of RAM to Docker and expect a 2–3 minute startup while it deploys L1 contracts.

### NIP-46 bunker

Enable the bunker profile when you need to test remote signing:

```bash
docker compose --profile bunker up -d --build
```

This starts a Bunker46 server (server only, no web UI) on `http://127.0.0.1:3001` with Postgres and Redis. Generate real secrets before using it outside of local testing:

```bash
cd dev-setup
cat > .env <<EOF
JWT_SECRET=$(openssl rand -base64 48)
JWT_REFRESH_SECRET=$(openssl rand -base64 48)
ENCRYPTION_KEY=$(openssl rand -base64 48)
EOF
docker compose --profile bunker up -d
```

For local bot development you can also use the daemon's `nsec` backend; do not commit private keys.

## Port reference

| Service | URL | Docker service |
|---------|-----|----------------|
| Nostr relay | `ws://localhost:7000` | `nostr-relay` |
| Anvil EVM | `http://localhost:8545` | `anvil` |
| Aztec sandbox | `http://localhost:8080` | `aztec-sandbox` (profile `aztec`) |
| Aztec admin | `http://localhost:8880` | `aztec-sandbox` (profile `aztec`) |
| NIP-46 bunker | `http://127.0.0.1:3001` | `nip46-bunker` (profile `bunker`) |

## Notes

- All images are built locally for the host architecture (arm64 on Apple Silicon, x86_64 on Linux). No `platform: linux/amd64` pinning or Rosetta emulation is required.
- First `docker compose up --build` will take several minutes because it compiles Foundry, nostr-rs-relay, Bunker46, and the Aztec wrapper from source.
- If Anvil emulation is too slow on an M4 Mac, run `anvil` natively via `foundryup` instead and stop the `anvil` container.
- Aztec's sandbox is the heaviest service. Do not start it unless you are actively working on `pacto-aztec`.
- Private keys should never be committed. The `nsec` signing backend is for local testing only.
