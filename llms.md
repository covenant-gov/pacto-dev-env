# llms.md — Pacto dev-env navigation

## What this repository is

`pacto-dev-env` is the local development-environment repository for the Pacto /
Covenant Gov ecosystem. It provides containerized backing services (Nostr relay,
Anvil EVM testnet, optional Aztec sandbox, optional NIP-46 bunker) and
host-setup scripts so contributors can build and test the sibling application
repositories locally.

## When to use this context

Reach for this document when the user asks about:

- Starting, stopping, or resetting the local Pacto service stack
- Seeding governance contracts or squads on Anvil
- Connecting a sibling repository to the shared Docker network or daemon volume
- Debugging Docker, Anvil, relay, or `pacto-bot-api` issues
- Understanding the relationship between `pacto-dev-env` and other repos

## Core commands

All commands are exposed through `Makefile` targets:

| Command | Purpose |
|---|---|
| `make up` | Start the default stack: `nostr-relay` + `anvil` + `pacto-bot-api` |
| `make up-all` | Start the full stack: default + Aztec + bunker + seed |
| `make seed` | One-shot deploy of Pacto governance contracts to Anvil |
| `make reseed` | `make reset` + `make up` + `make seed` |
| `make seed-squad` | Deploy a Nave Pirata squad (requires captain/candidate identities) |
| `make reseed-all` | `make reset` + `make up` + `make seed` + `make seed-squad` |
| `make check` | Verify host environment and running stack health |
| `make reset` | Stop all services, remove volumes, and clear local deployment artifacts |
| `make down` | Stop all services across all profiles |
| `make help` | List all targets with descriptions |

## Key files and directories

| Path | Purpose |
|---|---|
| `Makefile` | Developer command entrypoints |
| `docker-compose.yml` | Service definitions, profiles, networks, and volumes |
| `scripts/` | Bash helper scripts: setup, seed, verify, config init |
| `docker/` | Dockerfiles for the local Anvil/Foundry image and the debug sidecar |
| `data/` | Runtime data volumes mounted into containers; `data/deployments/31337/` holds governance and squad artifacts |
| `docs/` | Human-readable guides: setup, workflows, troubleshooting |
| `ARCHITECTURE.md` | Unified architecture and connection guide for sibling repos |
| `AGENTS.md` | Repository guidelines and conventions for agents |
| `llms.md` | This file |

## Architecture summary

- **Default stack:** `nostr-relay` (port 7000), `anvil` (port 8545, chain 31337), `pacto-bot-api` (Unix socket inside `pacto-bot-api-data` volume).
- **Optional profiles:** `aztec`, `bunker`, `seed`, `full` (combines all optional), `debug`.
- **Shared resources:**
  - Docker network: `pacto` (`external: true` from sibling composes)
  - Docker volume: `pacto-bot-api-data` (`external: true` from sibling composes)
  - Deployment artifacts: `data/deployments/31337/full-system.json` and `squad.json`
- **Sibling repositories** attach to these resources instead of defining their own services.

## Seeding behavior

- `make seed` reads `data/deployments/31337/full-system.json`. If it exists and the recorded `NavePirataFactory` is still live on Anvil, it exits. If the factory is missing (e.g., after a chain reset), it re-deploys automatically.
- `make seed-squad` validates the factory before calling `forge script`. If the factory is missing, it prints an actionable error: run `make seed` or `make reseed-all`.
- `FORCE_SEED=1` forces `make seed` to re-deploy. `FORCE_SEED_SQUAD=1` forces a new squad deploy.

## Sibling repositories

| Repo | Technology | What it consumes from this repo |
|---|---|---|
| `pacto-app` | Rust / Tauri | Nostr relay (`ws://localhost:7000`), Anvil EVM (`http://localhost:8545` or `https://localhost:8546`) |
| `pacto-gov` | Solidity / Foundry | Anvil EVM for `forge script` deployments |
| `pacto-governance-bots` | Rust / Python bots | `pacto-bot-api` Unix socket, Anvil EVM |
| `pacto-aztec` | Noir / TypeScript | Anvil EVM for L1, Aztec sandbox (optional) |
| `pacto-squad-sponsor` | Solidity | Anvil EVM |
| `delegated-security-manager` | Solidity | Anvil EVM |
| `nostr-k-derivs` | Rust | Nothing directly from this repo; key-derivation library |
| `pacto-download` | JavaScript | Nothing directly; distribution site |

## Common debugging paths

- Container health: `docker compose logs -f`
- Stack verification: `make check`
- Anvil RPC: `cast block-number --rpc-url http://localhost:8545` or `cast block-number --rpc-url https://localhost:8546 --insecure`
- Relay: `curl -s http://localhost:7000` or `websocat -k -1 wss://localhost:7001`
- TLS certs: generated automatically by `make up` via `scripts/generate-local-certs.sh` (uses mkcert when available, otherwise Caddy's internal CA)
- Daemon socket: `docker compose exec pacto-bot-api test -S /var/lib/pacto-bot-api/pacto-bot-api.sock`
- Debug sidecar: `docker compose --profile debug up -d --build` then `docker compose exec debug bash`

## Deeper reading

- Quick start: `README.md`
- Architecture and connection contract: `ARCHITECTURE.md`
- Setup details and prerequisites: `docs/setup.md`
- Per-project workflows: `docs/workflows.md`
- Troubleshooting: `docs/troubleshooting.md`
- Repository conventions: `AGENTS.md`

## Conventions to preserve

- Do not add `platform: linux/amd64` pinning; build natively for the host architecture.
- Prefer multi-stage Dockerfiles and non-root service users where applicable.
- Keep secrets in ignored files (`pacto-bot-api.toml`, `.env`), never in committed code.
- Use `make` targets as the primary developer interface; scripts are implementation details.
