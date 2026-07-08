---
date: 2026-07-07
topic: pacto-integration-hardening
type: feat
origin: /home/opselite/projects/covenant-gov/pacto-dev-env/INTEGRATION_REFLECTION.md
---

# Pacto Integration Hardening — Dev-Env, Daemon, and Governance Bot

## Summary

Harden the end-to-end integration between `pacto-dev-env`, `pacto-bot-api`, and `pacto-governance-bots` so a new contributor can go from `git clone` to a registered, event-receiving governance bot with a single documented flow. The work covers four areas: daemon capability and observability fixes, governance bot scaffolding and configuration fixes, dev-env onboarding conveniences, and cross-repo setup documentation and health checks.

## Problem Frame

The local stack now runs end-to-end, but several friction points make setup fragile and debugging opaque:

- The Python SDK exposes `agent.send_group_message` and `agent.publish_key_package`, but the daemon only authorizes `SendMessages`, so MLS group-message handlers fail to register.
- The daemon has no runtime version or health endpoint, and its event-tracing diagnostics report zero received/dispatched events even when events land on the relay.
- The scaffolded governance bot requests `SendGroupMessages` before the daemon supports it, the Compose file overrides `.env` values with empty-string defaults, and the bot publishes its KeyPackage before the transport is connected.
- `make up` produces a daemon-only config with no bot identity; `make seed` deploys governance contracts but does not help create a NavePirata squad; and registry/Hats addresses must be manually copied between repos.
- Cross-project handoffs are undocumented, so sibling repos disagree on volume names, socket paths, and the steps needed to verify a working integration.

## Key Decisions

- **Add `SendGroupMessages` to the daemon.** The daemon will recognize `SendGroupMessages` as a distinct capability alongside `SendMessages`, and authorize both `agent.send_group_message` and `agent.publish_key_package` under it. This aligns the daemon with the existing Python SDK and Rust governance-bot contract. `SendMessages` remains for DM-only handlers.
- **Keep squad creation identity-aware.** `make seed-squad` will not fabricate a dummy single-user squad. It will require the captain and candidate identities to be created first with `pacto-bot-admin` and passed via env vars, printing instructions when they are missing.
- **Generate `.env` from the deployment artifact in the bot repo.** `pacto-governance-bots` will ship a script that reads `../pacto-dev-env/data/deployments/31337/full-system.json` and writes `bots/bosun/.env`. `pacto-dev-env` will not own per-consumer dotenv files.
- **One-shot onboarding lives in `pacto-dev-env` as `make dev`.** The orchestration repo is the right home for the target that pulls images, starts the stack, creates a dev bot, seeds contracts, and prints the next commands for the sibling repo.
- **Observability first, custom dashboard later.** Event pipeline logging and `pacto-bot-admin doctor`/`diagnose` accuracy are prioritized over building a custom cross-protocol debug UI.

## Requirements

### Daemon (`pacto-bot-api`)

R1. The daemon recognizes `SendGroupMessages` as a valid bot capability and accepts handler registrations that request it.

R2. The daemon authorizes `agent.send_group_message` and `agent.publish_key_package` calls when the handler is registered with `SendGroupMessages`.

R3. `pacto-bot-admin --capabilities` validation and interactive prompts list `SendGroupMessages` as a valid value alongside `ReadMessages`, `SendMessages`, and `ManageProfile`.

R4. The daemon exposes a runtime `system.version` JSON-RPC method that returns the crate version and an embedded git short SHA. The optional HTTP transport exposes the same value at `GET /version`.

R5. The daemon exposes `system.health` (or `agent.status`) as a JSON-RPC method that returns config validity, relay connection state, registered handler count, and recent event counts.

R6. `pacto-bot-admin diagnose` and `pacto-bot-admin status` reflect real event counts: events received from the relay, decrypted, dispatched, and handler responses collected.

R7. The daemon logs the event pipeline at INFO level with structured lines covering: received from relay, decrypted, dispatched to handler, and handler response.

R8. The daemon honors the configured `socket_path` exactly, or auto-creates parent directories with safe permissions when an XDG-style path is configured. The default `pacto-dev-env` config and the governance bot Compose default must agree on one path.

R9. `main`-tagged Docker images embed the short git SHA in `--version` output, replacing the current `0.6.0 (unknown)`.

### Governance bot (`pacto-governance-bots`)

R10. The scaffolded bot template uses a capability compatible with the daemon. After `SendGroupMessages` lands, the template requests `SendGroupMessages` for group-message bots.

R11. `docker-compose.yml` removes empty-string defaults for optional environment variables so that `bots/bosun/.env` is the single source of truth. Variables are only declared in Compose when there is a meaningful default.

R12. A root `.env.example` documents the environment variable load order and the shared contract from `pacto-dev-env`.

R13. The external volume reference matches the name created by `pacto-dev-env` (`pacto-dev-env_pacto-bot-api-data`) and is documented so new sibling repos know the convention.

R14. The bot publishes its MLS KeyPackage after the transport is connected, not before, removing the "transport not connected" warning on startup.

R15. The "no deployments in registry" error includes a hint pointing to the squad-creation instructions in `pacto-dev-env`.

R16. The repository includes a script that reads `../pacto-dev-env/data/deployments/31337/full-system.json` and writes `bots/bosun/.env` with the correct registry/Hats addresses, socket path, and RPC URL.

### Dev-env (`pacto-dev-env`)

R17. `make up` can optionally create a dev bot identity when none exists, gated behind an env var such as `PACTO_CREATE_DEV_BOT=1`.

R18. `make seed-squad` runs a guided helper that checks for required captain/candidate identities and, when present, executes `DeployNavePirata.s.sol` against the local Anvil node. When identities are missing, it prints explicit `pacto-bot-admin new` instructions.

R19. `make dev` combines pull/start stack, optional dev-bot creation, contract seeding, and printed next steps for the sibling repo. It does not attempt automated squad creation.

R20. `README.md` documents the shared network/volume contract: `pacto` network, `pacto-bot-api-data` volume, socket path, and deployment artifact location.

R21. The image tag strategy is pinned or documented: `main` is the development default with `pull_policy: always` where desired; `latest` maps to releases.

### Cross-repo integration

R22. A single `SETUP.md` spans both `pacto-dev-env` and `pacto-governance-bots`, walking through clone, start, identity creation, contract seeding, squad creation, `.env` generation, bot start, and verification.

R23. `pacto-governance-bots` includes an integration health check that verifies: daemon reachable via socket, bot identity present in daemon config, handler registered, anvil has at least one squad, and registry/Hats addresses in the bot's `.env` match the deployment artifact.

R24. Both repos agree on a unified default socket path; if the daemon uses an XDG layout, `pacto-governance-bots` default env and Compose match it exactly.

## Actors

- **New contributor** — runs `make dev` and expects the stack and bot to work without reading multiple READMEs.
- **Bot operator** — starts `pacto-governance-bots` and needs correct `.env` values and clear diagnostics when something is misconfigured.
- **Daemon maintainer** — adds capabilities and observability without breaking existing DM-only handlers.
- **Dev-env maintainer** — adds convenience targets without hiding manual steps that require real identities.

## Key Flows

### F1. First-time contributor onboarding

- **Trigger:** A new contributor clones `pacto-dev-env` and `pacto-governance-bots`.
- **Actors:** New contributor.
- **Steps:**
  1. Run host setup script.
  2. Run `make dev` in `pacto-dev-env` to start services and seed contracts.
  3. Follow printed instructions to create a dev bot identity and squad identities with `pacto-bot-admin`.
  4. Run `make seed-squad` with the required identities.
  5. Run `make env` (or equivalent) in `pacto-governance-bots` to generate `bots/bosun/.env`.
  6. Start the bot with `docker compose up -d`.
  7. Run the integration health check to confirm handler registration and event flow.
- **Outcome:** The bot is registered with the daemon and ready to receive events.

### F2. Daily bot operator restart

- **Trigger:** Operator pulls latest images and restarts the stack.
- **Actors:** Bot operator.
- **Steps:**
  1. `make pull` in `pacto-dev-env`.
  2. `make up` in `pacto-dev-env`.
  3. `docker compose up -d` in `pacto-governance-bots`.
  4. `pacto-bot-admin doctor` or the integration health check confirms the bot is registered.
- **Outcome:** Services restart and the bot reconnects without manual `.env` edits.

### F3. Debugging event flow

- **Trigger:** Operator suspects events are not reaching the bot.
- **Actors:** Bot operator.
- **Steps:**
  1. Run `pacto-bot-admin diagnose --format json`.
  2. Check structured INFO logs for received/decrypted/dispatched counts.
  3. If counts are zero, check relay health and socket path alignment.
  4. If dispatch count is zero, check handler registration and capabilities.
- **Outcome:** Operator identifies which pipeline stage is dropping events.

## Acceptance Examples

### AE1. Covers R1, R2, R3.

- **Given:** A handler registers with `capabilities: ["SendGroupMessages"]` and the bot config grants `SendGroupMessages`.
- **When:** The handler calls `agent.send_group_message` and `agent.publish_key_package`.
- **Then:** Both calls succeed and the daemon publishes the corresponding Nostr events.

### AE2. Covers R4, R5.

- **Given:** The daemon is running with the HTTP transport enabled.
- **When:** A client calls `system.version` via JSON-RPC and `GET /version` via HTTP.
- **Then:** Both return the same `{version, git_sha}` object, and `git_sha` is not `"unknown"` for `main`-tagged images.

### AE3. Covers R6, R7.

- **Given:** A gift-wrapped DM is published to the local relay and routed to a registered handler.
- **When:** `pacto-bot-admin diagnose` runs afterward.
- **Then:** `recent_counts` shows at least one event received, one decrypted, one dispatched, and one handler response.

### AE4. Covers R11, R12, R13.

- **Given:** `bots/bosun/.env` sets `PACTO_GOVERNANCE_REGISTRY=0x1234...` and Compose does not declare the variable.
- **When:** The bot container starts.
- **Then:** The container sees `PACTO_GOVERNANCE_REGISTRY=0x1234...`, not an empty string.

### AE5. Covers R16, R24.

- **Given:** `../pacto-dev-env/data/deployments/31337/full-system.json` exists with `navePirataRegistry` and `hats`.
- **When:** The operator runs the env generator script in `pacto-governance-bots`.
- **Then:** `bots/bosun/.env` is created with matching registry and hats addresses and the agreed socket path.

### AE6. Covers R18, F1.

- **Given:** `make seed` has run and produced deployment artifacts, but no squad exists yet.
- **When:** `make seed-squad` runs without the required captain/candidate env vars.
- **Then:** It prints explicit `pacto-bot-admin new` instructions and exits with a clear message, without deploying a dummy squad.

## Scope Boundaries

### Deferred for later

- Phase 2 inbound `!snapshot` command for the governance bot. See `docs/brainstorms/2026-07-05-python-governance-snapshot-bot-requirements.md`.
- TEE deployment architecture for the governance bot. Already covered in `docs/plans/2026-07-03-001-feat-governance-snapshot-mls-tee-bot-plan.md`.
- A custom cross-protocol debug dashboard. The current scope improves observability through logs and diagnostics; a purpose-built UI is a future nice-to-have.

### Outside this product's identity

- Replacing or removing the Rust governance crate (`crates/governance-bot/`). The Python bot is a sibling implementation.
- Modifying the daemon's MLS extension or JSON-RPC contract beyond the `SendGroupMessages` capability and the version/health endpoints described here.
- A general-purpose no-code bot builder.

## Dependencies and Assumptions

- The `pacto-bot-api` MLS extension already implements `agent.send_group_message` and `agent.publish_key_package` on the SDK side; only daemon authorization and capability recognition are missing.
- `pacto-bot-admin` can create multiple bot identities on the same machine and append them to `pacto-bot-api.toml`.
- `pacto-gov` is available at `../pacto-gov` (or `PACTO_GOV_DIR`) and contains `script/DeployNavePirata.s.sol`.
- The `pacto-governance-bots` local clone is at `../pacto-governance-bots` relative to `pacto-dev-env` so the env generator can read the deployment artifact with a default relative path.
- The governance bot's Python SDK supports `handler.register`, `agent.publish_key_package`, and `agent.send_group_message` through the `Bot` / `PactoClient` API.

## Outstanding Questions

### Resolve before planning

None.

### Deferred to planning

- Exact JSON shape for `system.version` and `system.health` responses.
- Whether `agent.status` should be extended or a new `system.health` method added.
- Whether the env generator should live in `scripts/` or `bots/bosun/scripts/`.
- Whether `make dev` should default `PACTO_CREATE_DEV_BOT=1` or require explicit opt-in.

## Sources and Research

- `/home/opselite/projects/covenant-gov/pacto-dev-env/INTEGRATION_REFLECTION.md` — the original blueprint identifying capability drift, config mismatch, and onboarding gaps.
- `pacto-bot-api/schemas/jsonrpc.json` — existing `agent.send_group_message` and `agent.publish_key_package` methods.
- `pacto-bot-api/src/admin.rs`, `src/handlers.rs`, `src/dispatch.rs` — capability validation, registration, and authorization logic.
- `pacto-bot-api/AGENTS.md` — daemon architecture, conventions, and testing preferences.
- `pacto-dev-env/AGENTS.md` and `README.md` — existing dev-env stack, profiles, and shared-network contract.
- `pacto-dev-env/scripts/seed-anvil.sh` and `pacto-gov/script/DeployNavePirata.s.sol` — existing seeding and per-squad deployment scripts.
- `pacto-governance-bots/AGENTS.md` and `docker-compose.yml` — current bot orchestration and env var defaults.
- `pacto-governance-bots/docs/2026-07-05-python-governance-snapshot-bot-requirements.md` and `docs/2026-07-05-001-feat-python-governance-snapshot-bot-plan.md` — prior requirements and plan for the standalone Python governance bot.
