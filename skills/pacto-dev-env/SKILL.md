---
name: pacto-dev-env
description: Set up and manage the Pacto local development environment from any Pacto repo. Clone, bootstrap, start services, configure the current repo, and troubleshoot common issues like Caddy TLS errors. Use when the user mentions dev-env, local services, connecting to the relay/Anvil, or SSL errors.
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# Pacto Dev Environment Skill

Manage the Pacto local development environment from any Pacto repository. If the environment is not present, this skill clones it, runs the host setup script, starts the services, clones sibling repositories, and configures the current repository to connect.

## Subcommands

Use `/pacto-dev-env <subcommand>`.

### `setup` — Bootstrap the workspace and start services

1. Determine the base directory: use `PACTO_DEV_ENV_DIR` if set, otherwise `~/src/covenant-gov/pacto-dev-env`.
2. If `pacto-dev-env` is missing, clone it from `https://github.com/covenant-gov/pacto-dev-env.git` into that directory.
3. Run the bootstrap helper inside the cloned repo: `bash "${PACTO_DEV_ENV_DIR}/scripts/skill-bootstrap.sh"`.
4. The helper will interview the user to decide which service stack to start:
   - **Connect a frontend** (e.g., `pacto-app`) → `make up` (nostr-relay, anvil, pacto-bot-api).
   - **Test governance / Aztec / bunker** → `make up-all` (default + aztec + bunker + contract seed).
   - **Seed a Nave Pirata squad** → `make up-all && make seed-squad`.
   - **Create an MLS group** → `make up-all && make seed-squad && make create-mls-group`.
   - **Use existing bots** → `make up-all` after verifying `pacto-bot-api.toml` has bots.
   - **Not sure** → show the raw stack menu and ask the user to pick.
   
   In non-interactive contexts the helper defaults to `make up`.
5. The helper also:
   - Detects the host platform (macOS arm64 or Ubuntu LTS).
   - Runs the appropriate setup script (`./setup-macos-arm64.sh` or `sudo ./setup-ubuntu-lts.sh`).
   - Clones missing sibling repos (`pacto-app`, `pacto-gov`, `pacto-bot-api`, `pacto-aztec`) into the same base directory.
6. Report which services are running and which ports are exposed.

For automated use, set `PACTO_START_MODE` to one of `default`, `full`, `squad`, `group`, or `bots` before invoking the script. Group mode also requires `RECIPIENT_NPUB`; `BOT_ID` defaults to `bosun` and `GROUP_NAME` to `local-dev-squad`.

### `status` — Check the dev environment

1. Locate the dev environment directory.
2. Run `make check` in that directory.
3. If services are not running, report which ones and suggest `make up` or `make up-all`.

### `connect` — Configure the current repo to use the dev environment

1. Locate the dev environment directory.
2. Run the configure helper: `bash "${PACTO_DEV_ENV_DIR}/scripts/skill-configure-repo.sh"`.
3. The helper will detect which Pacto repo is current and write or update the appropriate configuration (env files, Tauri config, Foundry settings, etc.).
4. If the current repo is not a known Pacto repo, print the environment variables the user should paste.

### `troubleshoot ssl` — Fix Caddy/self-signed certificate issues

1. Check if `mkcert` is installed.
2. If not, prompt the user to install it and run `mkcert -install`, then regenerate Caddy certificates with `make certs` in the dev environment.
3. If Caddy is using its self-signed CA, explain that clients must skip TLS verification or trust the certificate.
4. Verify that the wss/https endpoints respond.

## Safety rules

- Never commit private keys, `pacto-bot-api.toml`, or `.env` files with real secrets.
- Before running `sudo ./setup-ubuntu-lts.sh`, confirm with the user if running in a non-interactive context.
- Before overwriting existing config files, show a diff and ask for confirmation.
- Respect `PACTO_DEV_ENV_DIR` for all dev-env paths.
