# Blueprint: Simplifying and Hardening the Pacto Dev-Env + Daemon + Governance Bot Integration

## 1. Current state

The stack now runs end-to-end in the local environment:
- `pacto-dev-env` (relay, anvil, aztec, bunker, daemon) is healthy.
- Daemon is on the `main` image with `pull_policy: always`.
- `bosun` bot identity exists and registers with the daemon.
- `bosun` container connects over the Unix socket and receives `dm_received` events.

However, several friction points remain that make the setup fragile and hard to reason about.

---

## 2. Problems identified

### A. Daemon: capability and API drift
- The Python SDK exposes `agent_send_group_message(...)` and `agent_publish_key_package(...)`, but the daemon does **not** recognize `SendGroupMessages` as a handler capability. Registration fails if a bot asks for it.
- The daemon has no runtime `version` or `health` JSON-RPC/HTTP endpoint. Operators must `docker exec` and run `--version`.
- Event tracing (`trace-events`, `diagnose`) shows zero received/dispatched events even when events land on the relay, making debugging opaque.

### B. Governance bot: generated code and config are out of sync
- The scaffolded `bosun.py` requests `capabilities=["SendGroupMessages"]`, which the daemon rejects. It had to be changed to `SendMessages`.
- `docker-compose.yml` declared empty-string defaults for optional env vars (`REGISTRY`, `HATS`, etc.), which overrode populated values in `.env` and caused startup failures.
- The `pacto-bot-api-data` external volume name did not match the name created by `pacto-dev-env`.
- The bot's `setup()` publishes a KeyPackage before the transport is connected, so the first attempt always warns "transport not connected".

### C. Dev-env: missing convenience for bot identity and squad creation
- `make up` produces a daemon-only config with no bot identity. The user must know to run `pacto-bot-admin new` before any handler can register.
- `make seed` deploys governance master copies and registry, but does **not** create a NavePirata squad. `deploymentCount()` is `0`, so the snapshot reader fails with a confusing error.
- No single command gets a new contributor from `git clone` to "bot registered and ready to test".

### D. Cross-project handoffs are undocumented
- `pacto-governance-bots` expects the `pacto` network and `pacto-bot-api-data` volume from `pacto-dev-env`, but the actual volume name is `pacto-dev-env_pacto-bot-api-data`.
- Socket path defaults differ between the daemon config and the bot config.
- Registry/Hats addresses must be manually copied from `pacto-dev-env/data/deployments/31337/full-system.json` into `bots/bosun/.env`.

---

## 3. Recommended changes (blueprint)

### 3.1 Daemon (`pacto-bot-api`)

| Change | Why |
|---|---|
| **Add `SendGroupMessages` capability** | Align daemon enforcement with the SDK's `agent_send_group_message` method. Update `pacto-bot-admin --capabilities` valid set and `handler.register` validation. |
| **Add runtime `system.version` JSON-RPC method** | Lets handlers and health checks verify daemon version without exec'ing. Also expose `GET /version` on the optional HTTP transport. |
| **Add `system.health` / `agent.status` method** | Return config validity, relay connection, handler count, and recent event counts in one call. |
| **Log event pipeline at INFO level** | Emit structured lines for: event received -> decrypted -> dispatched -> handler response. Populate `event_trace` and `diagnose` `recent_counts` from this pipeline. |
| **Honor `socket_path` exactly or auto-create parent dirs** | Remove the surprise that config says one path but daemon listens on another. If XDG layout is desired, make it explicit and documented. |
| **Include git revision in `main` builds** | The `main` image currently reports version `0.6.0 (unknown)`. Embed the short SHA so `pacto-bot-api --version` is useful. |

### 3.2 Governance bot (`pacto-governance-bots`)

| Change | Why |
|---|---|
| **Update scaffold template to use `SendMessages`** | Stop generating broken bots out of the box. Or, once daemon supports it, use `SendGroupMessages` consistently. |
| **Remove empty-string defaults from `docker-compose.yml`** | Let `bots/bosun/.env` be the single source of truth. Only declare vars in Compose when there is a meaningful default. |
| **Add a root `.env.example` and document the load order** | Make it obvious that `PACTO_GOVERNANCE_*` can live in a root `.env` or `bots/bosun/.env`. |
| **Fix external volume reference** | Point to the real `pacto-dev-env_pacto-bot-api-data` volume name (already done), or make `pacto-dev-env` use predictable un-prefixed names. |
| **Defer KeyPackage publish until after transport connect** | In `BosunBot.amain()`, call `setup()` after the dispatch loop has connected, not before. This removes the "transport not connected" warning. |
| **Improve the "no deployments in registry" error** | Include a hint: "Run `make seed-squad` in pacto-dev-env or deploy a NavePirata squad." |

### 3.3 Dev-env (`pacto-dev-env`)

| Change | Why |
|---|---|
| **`make up` should create a dev bot identity if none exists** | Add a non-interactive `pacto-bot-admin new dev-bot --backend nsec ...` step in the config init script, gated behind an env var like `PACTO_CREATE_DEV_BOT=1`. |
| **Add `make seed-squad` target** | Run `forge script DeployNavePirata.s.sol` with defaults (deployer as captain, dummy metadata URI) so there is a squad index `0` for the bot to read. |
| **Add `make setup` or `make dev` one-shot target** | Combine: pull images -> start stack -> create dev bot -> seed contracts -> seed squad -> print `.env` snippet for `pacto-governance-bots`. |
| **Document the shared network/volume contract** | In `README.md`, state exactly what `pacto-governance-bots` expects: `pacto` network, `pacto-bot-api-data` volume, socket path, and deployment artifact location. |
| **Pin or document image tag strategy** | Decide whether `main` is the development default and `latest` is the stable release. Add `pull_policy: always` to `main`-tagged services where desired. |

### 3.4 Cross-project integration

| Change | Why |
|---|---|
| **Single `SETUP.md` spanning both repos** | Walk through: clone both repos, start dev-env, create bot, seed squad, copy env, start bot, verify with `pacto-bot-admin doctor`. |
| **Integration health check** | Add a script in `pacto-governance-bots` that verifies: daemon reachable, bot identity present, handler registered, anvil has squad, registry address matches. |
| **Automated `.env` generation** | A script in `pacto-governance-bots` reads `../pacto-dev-env/data/deployments/31337/full-system.json` and emits `bots/bosun/.env` with the correct registry/hats addresses and socket path. |
| **Unified socket path convention** | Both repos should agree on one default. If daemon uses XDG layout, `pacto-governance-bots` default env and Compose should match it exactly. |

---

## 4. Suggested implementation phases

### Phase 1 - Stop the bleeding (days)
1. Merge the daemon capability fix for `SendGroupMessages` or update the bot template to use `SendMessages`.
2. Clean up `pacto-governance-bots/docker-compose.yml` empty-string env defaults.
3. Document the shared network/volume names and socket path.

### Phase 2 - Developer experience (week)
1. Add `make seed-squad` to `pacto-dev-env`.
2. Add optional dev-bot creation to `pacto-dev-env` init.
3. Add `.env` generator script in `pacto-governance-bots`.
4. Add `make setup` one-shot target.

### Phase 3 - Observability and hardening (week)
1. Add `system.version` and `system.health` JSON-RPC methods to daemon.
2. Improve event pipeline logging and `trace-events` population.
3. Add integration health check spanning both repos.
4. Fix KeyPackage publish ordering in `bosun.py`.

### Phase 4 - Release hygiene (ongoing)
1. Ensure `main` builds embed git SHA in `--version`.
2. Decide and document image tag strategy (`latest` = release, `main` = dev).
3. Add CI test that registers a scaffolded bot against the daemon image.

---

## 5. Expected outcomes

- A new contributor can go from `git clone` to a registered, event-receiving governance bot in one command.
- `pacto-bot-admin doctor` reflects reality, including event dispatch.
- The bot template is compatible with the daemon it talks to.
- Debugging event flow does not require reading Rust debug logs.
- Image updates are intentional and verifiable via a runtime version endpoint.
