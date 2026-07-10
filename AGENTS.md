# Repository Guidelines

## Project Overview

`pacto-dev-env` is the local development-environment repository for the Pacto / Covenant Gov ecosystem. It provides containerized backing services (Nostr relay, Anvil EVM testnet, optional Aztec sandbox, optional NIP-46 bunker) and OS-specific one-shot host setup scripts so contributors can build and test the sibling application repositories.

## Architecture & Data Flow

This repository is a **service orchestration layer**, not an application.

- **Default stack** starts three services:
  - `nostr-relay` on `ws://localhost:7000`
  - `anvil` EVM testnet on `http://localhost:8545` (chain 31337)
  - `pacto-bot-api` daemon on a Unix socket inside the `pacto-bot-api-data` volume
- **Optional Compose profiles** extend the stack:
  - `--profile aztec` adds `aztec-sandbox` (`http://localhost:8080`, admin `http://localhost:8880`); it waits for Anvil to be healthy and deploys rollup contracts to it.
  - `--profile bunker` adds `nip46-bunker` (`http://127.0.0.1:3001`) backed by Postgres and Redis.
  - `--profile seed` runs a one-shot deploy of the Pacto governance contracts to Anvil and writes artifacts to `./data/deployments/31337/`.
  - `--profile full` adds `aztec-sandbox`, `nip46-bunker`, and the `seed` governance seeder.
  - `--profile debug` adds `debug`, an interactive sidecar with network/WebSocket inspection tools.
- **Host setup scripts** install Docker, Rust, Node/pnpm, Foundry, Aztec CLI, and clone the ecosystem repos into `~/src/covenant-gov/`.
- `docker-compose.yml` creates a shared `pacto` network. Sibling application composes should attach to it as `external: true` rather than duplicating these services.
- Sibling application repos (e.g., `pacto-app`, `pacto-gov`) connect to these localhost endpoints (or to the `pacto` Docker network from inside containers) during local development.

## Key Directories

| Directory | Purpose |
|---|---|
| `docker/` | Local Dockerfiles for `anvil` (built locally) and `debug`; prebuilt GHCR images are used for `nostr-relay`, `aztec-sandbox`, and `nip46-bunker`. |
| `data/` | Runtime data volumes mounted into containers (`data/relay`, `data/aztec`, `data/nip46-bunker-db`). |

## Development Commands

### Host setup

Apple Silicon:

```bash
./setup-macos-arm64.sh [base-dir]
```

Ubuntu 24.04/24.10/26.04 LTS:

```bash
sudo ./setup-ubuntu-lts.sh [base-dir]
```

Both default to cloning repos into `~/src/covenant-gov/`. After running, open a new shell so PATH changes take effect.

### Start local services

Generate `pacto-bot-api.toml` from the example (the real file must be kept secret and is ignored by Git), then start the stack:

```bash
cp pacto-bot-api.toml.example pacto-bot-api.toml
chmod 600 pacto-bot-api.toml
# Add bot identities with `pacto-bot-admin`, e.g.:
# pacto-bot-admin new bosun --backend nsec --relays ws://localhost:7000 >> pacto-bot-api.toml

make up          # default stack: relay + anvil + pacto-bot-api
make up-all      # default stack + aztec + bunker + seed
make reseed      # reset, restart, and re-deploy governance contracts
make reseed-all  # reset, restart, deploy contracts, and seed a squad
```

`make up` is equivalent to `docker compose up -d --build`. The `nostr-relay` image is pulled from GHCR; `anvil` is built locally on first run because its GHCR image is not yet available.

`make up-all` and `make seed` automatically run `scripts/ensure-sibling-repos.sh`, which checks for the sibling `pacto-gov` repository and its Node dependencies. If either is missing, the script interactively offers to clone the repo and run `pnpm install`. In non-interactive environments, use `make up-all YES=1` to allow automatic cloning and installation. `make seed` is idempotent and detects stale deployment artifacts: if the recorded `NavePirataFactory` is no longer live on Anvil (for example, after the chain was reset), it re-deploys automatically instead of failing silently.

### Verify the stack

`make check` runs `make check-env` (host tool verification) followed by the running-service health checks, and reports the versions of anvil, nostra (nostr-relay), and pacto-bot-api. `make check-env` only checks the host environment and prints remediation steps for missing tools (for example, run `setup-macos-arm64.sh` or `setup-ubuntu-lts.sh`).

### Optional profiles

Aztec sandbox:

```bash
docker compose --profile aztec up -d --build
```

NIP-46 bunker (generate real secrets first):

```bash
cp .env.example .env
# edit .env with secure secrets
docker compose --profile bunker up -d --build
```

### Creating an MLS group

`pacto-dev-env` ships with a single-command MLS group creation workflow:

```bash
make create-mls-group BOT_ID=bosun RECIPIENT_NPUB=<captain-npub> GROUP_NAME=local-dev-squad
```

The command:
1. Validates that the creator bot (`bosun` by default) has the `Admin`
   capability and an MLS engine (`mls_db_path`) in `pacto-bot-api.toml`.
2. If the recipient is a bot configured in `pacto-bot-api.toml` with MLS
   capabilities and no KeyPackage is on the relay, it publishes one
   automatically.
3. Polls the relay until the recipient's KeyPackage (kind:443) appears.
4. Calls `pacto-bot-admin mls-group create` inside the `pacto-bot-api`
   container.
5. Writes the group artifact to `data/deployments/31337/group-<BOT_ID>.json`,
   even when that directory is root-owned from earlier seed scripts.
6. Prints the group wire ID.

Requirements:

- The creator bot must have the `Admin` capability and an MLS engine
  (`mls_db_path`) configured in `pacto-bot-api.toml`.
- The recipient must have a fresh KeyPackage (kind:443) on the relay. For a
  human, this means opening the Pacto desktop app (`pacto-app`). For a bot,
  run `make publish-key-package BOT_ID=<bot>` first (or let the create script
  do it automatically for a configured bot).

Other useful targets:

- `make publish-key-package BOT_ID=captain` — publish a KeyPackage for a bot
  by registering a temporary handler and calling `agent.publish_key_package`.
- `make check-group` — print the group artifact(s) and daemon MLS database
  state.

If the daemon command fails with `-32602 invalid params`, the published
`pacto-bot-api` image is stale. The `make up` target now builds from the
sibling `../pacto-bot-api` repo when it exists, or you can rebuild manually:

```bash
make build-pacto-bot-api
```

## Code Conventions & Common Patterns

- **Bash setup scripts**
  - `setup-ubuntu-lts.sh` is idempotent: checks `dpkg` status, tests `command -v`, and uses `append_if_missing` for shell rc edits.
  - `setup-macos-arm64.sh` checks command existence before installing but re-appends the environment block to the shell rc on every run.
  - Both append `~/.cargo/bin`, `~/.foundry/bin`, and `~/.aztec/bin` to PATH.
- **Docker builds**
  - Prefer source builds for native architecture (arm64 on Apple Silicon, x86_64 on Linux) instead of `platform:` pinning or Rosetta emulation.
  - Multi-stage Dockerfiles with dedicated runtime images (`debian:bookworm-slim` or `node:24-slim`).
  - Services run as non-root users where applicable (`relay` uid 1000, `bunker` uid 1001).
- **Compose patterns**
  - Use profiles (`aztec`, `bunker`, `full`, `debug`) to keep heavy or optional services opt-in.
  - The default stack is `nostr-relay` + `anvil`; `relay` is no longer a profile.
  - Healthchecks gate service dependencies (e.g., Aztec waits for Anvil; bunker waits for Postgres and Redis). The `debug` profile has no dependencies and can be started standalone.
  - The shared `pacto` network lets sibling app composes reach services by service name instead of duplicating them.

### Debugging playbook

When investigating service connectivity or protocol issues, prefer these tools:

- **Host-side (already installed by setup scripts):** `cast`, `curl`, `jq`, `nak`, `socat`, `websocat`.
- **Container-side (debug sidecar):** start `docker compose --profile debug up -d --build` and attach with `docker compose exec debug bash`.
  - `websocat ws://nostr-relay:8080` for raw Nostr WebSocket frames.
  - `nak req -k 443 -a <bot_pubkey_hex> ws://nostr-relay:8080` to inspect a bot's MLS KeyPackage event on the relay.
  - `socat -v TCP-LISTEN:7001,fork TCP:nostr-relay:8080` to proxy/tap relay traffic.
  - `curl -fsS -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://anvil:8545 | jq .` for EVM RPC checks.
  - `psql postgresql://bunker46:bunker46@nip46-bunker-db:5432/bunker46` for bunker database inspection.
  - `redis-cli -h nip46-bunker-redis ping` for bunker cache checks.
  - `nc -zv <service> <port>` for quick port-open verification.

---

## Configuration

- `relay-config.toml` is mounted read-only into the relay container.
- Bunker secrets are injected via `.env`; default placeholders are insecure and must be overridden.

## Important Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Service definitions, profiles, ports, volumes, and healthchecks. |
| `relay-config.toml` | Nostr relay runtime config (SQLite, allow-listed event kinds). |
| `setup-macos-arm64.sh` | Host setup for Apple Silicon. |
| `setup-ubuntu-lts.sh` | Host setup for Ubuntu LTS (run with `sudo`). |
| `docker/nostr-relay.Dockerfile` | Local fallback build for `nostr-rs-relay` v0.9.0 from source. |
| `docker/anvil.Dockerfile` | Builds Foundry v1.7.1 (`anvil`, `cast`, `forge`, `chisel`) from source; used by the default stack. |
| `docker/nip46-bunker.Dockerfile` | Local fallback build for Bunker46 server (no UI) with Node 24/pnpm. |
| `docker/debug.Dockerfile` | Sidecar image with `socat`, `websocat`, `curl`, `jq`, `nc`, `psql`, `redis-cli`. |
| `scripts/ensure-sibling-repos.sh` | Ensures the sibling `pacto-gov` repo and its dependencies are present before seeding. |
| `scripts/seed-anvil.sh` | One-shot deploy of Pacto governance contracts to Anvil. |
| `scripts/verify-env.sh` | Verifies the host has the required tools (Docker, Rust, Foundry, etc.) and prints remediation steps. |
| `scripts/verify-stack.sh` | Verifies the running Docker Compose services are healthy and reachable. |
| `pacto-bot-api.toml.example` | Template for the daemon config; copy to `pacto-bot-api.toml` and add bot identities. |
| `pacto-bot-api.toml` | Generated daemon config with signing material; **never commit**. |
| `ARCHITECTURE.md` | Unified architecture, operations, and connection guide for this repository. |
| `README.md` | Quick-start and full developer guide with per-project workflows. |

## Runtime/Tooling Preferences

- **Container runtime**: Docker Engine + Docker Compose plugin.
- **Shell**: Bash; setup scripts target `zsh`/`bash` rc files.
- **Host toolchains installed by setup scripts**:
  - Rust (stable) with `rustfmt` and `clippy`
  - Node 20 / pnpm
  - Foundry (`anvil`, `cast`, `forge`)
  - Aztec sandbox version manager
- **Architecture**: Native arm64/amd64 builds; avoid `platform: linux/amd64` pinning.

## Testing & QA

- There is no automated test suite in this repository.
- Setup script health is checked by `verify_install()` at the end of each script, which prints versions of Docker, Docker Compose, Rust, Node, pnpm, Foundry, and Aztec.
- Service health is verified through Docker Compose healthchecks and the port reference in `README.md`.
- When modifying a Dockerfile or setup script, test the affected path end-to-end on the target platform before considering it done.
