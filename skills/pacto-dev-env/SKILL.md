---
name: pacto-dev-env
description: Pacto onboarding and connection hub. Help new contributors set up their AI workspace, connect any Pacto repo to the local dev environment, and route to the right Compound Engineering workflow for adding, fixing, planning, brainstorming, or exploring the codebase.
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# Pacto Dev Environment & Onboarding Skill

This skill is the front door for the Pacto ecosystem. It onboards new contributors, connects sibling repos to the local dev environment, and guides users to the right Compound Engineering workflow.

Use `/pacto-dev-env <subcommand>` or run this skill when the user mentions dev-env, local services, onboarding, connecting a repo, getting started, or exploring the Pacto codebase.

## Onboarding interview

Start every setup/onboarding/connect request with a short interview. The goal is to understand what the user is trying to do so you can route them to the right tool, not to dump every option on them.

Ask one of these questions (pick the one that fits the context):

> "What are you hoping to do? Set up your local dev environment, connect the current repo to it, add a feature, fix a bug, plan or brainstorm, or explore a repo?"

Map the answer to the path below:

| User goal | Next step |
|-----------|-----------|
| Set up / onboard / first time here | Run the workspace setup checklist below. |
| Connect the current repo to the dev env | Run `/pacto-dev-env connect`. |
| Add a feature, fix a bug, or change code | Ask which repo/area, then run `/ce-work` or `/ce-plan` if the scope is unclear. |
| Plan or brainstorm | Run `/ce-brainstorm` or `/ce-plan`. |
| Get information / explore a repo | Use `/understand` on the relevant sibling repo or run `/pacto-dev-env repo`. |
| Not sure / help me decide | Summarize the options, ask one clarifying question, and recommend the most likely path. |

## Workspace setup checklist

When the user is onboarding or setting up their AI workspace:

1. **Pacto dev environment**
   - Determine the base directory: use `PACTO_DEV_ENV_DIR` if set, otherwise `~/src/covenant-gov/pacto-dev-env`.
   - If `pacto-dev-env` is missing, clone it from `https://github.com/covenant-gov/pacto-dev-env.git`.
   - Run the platform setup: `bash "${PACTO_DEV_ENV_DIR}/scripts/skill-bootstrap.sh"`.
   - The bootstrap script will interview the user to choose the service stack (default, full, squad, group, bots). Set `PACTO_START_MODE` to skip the interview in non-interactive contexts.

2. **Sibling repositories**
   - The bootstrap script clones `pacto-app`, `pacto-gov`, `pacto-bot-api`, and `pacto-aztec` into the same base directory.
   - If the user wants to work on a specific repo, make sure it is cloned and up to date.

3. **Compound Engineering skills**
   - Check whether the Compound Engineering skill set is available in this workspace (e.g., `ce-brainstorm`, `ce-plan`, `ce-work`, `ce-code-review`, `ce-commit-push-pr`, `ce-debug`).
   - If not, tell the user how to install them for their harness and offer to wait while they do so.
   - Mention the workflows they will use most often:
     - `/ce-brainstorm` — explore ideas and requirements.
     - `/ce-plan` — turn a decision into a structured plan.
     - `/ce-work` — execute a scoped task.
     - `/ce-code-review` — review a PR or diff.
     - `/ce-commit-push-pr` — commit and ship a change.
     - `/ce-debug` — trace a failure.

4. **Connect the current repo**
   - Run `/pacto-dev-env connect` to configure the repo to use the local dev environment.
   - Print the connection URLs and next steps.

## Subcommands

Use `/pacto-dev-env <subcommand>`.

### `setup` — Bootstrap the workspace and start services

1. Run the onboarding interview above.
2. If the user wants dev-env setup, run the workspace setup checklist.
3. If the user wants to add/fix/plan/brainstorm, route to the appropriate Compound Engineering workflow instead of running the bootstrap script.
4. Report what was done and what the next command should be.

### `connect` — Configure the current repo to use the dev environment

1. Locate the dev environment directory.
2. Run the configure helper: `bash "${PACTO_DEV_ENV_DIR}/scripts/skill-configure-repo.sh"`.
3. The helper detects which Pacto repo is current and writes or updates the appropriate configuration (env files, Tauri config, Foundry settings, etc.).
4. If the current repo is not a known Pacto repo, print the environment variables the user should paste.

### `status` — Check the dev environment

1. Locate the dev environment directory.
2. Run `make check` in that directory.
3. If services are not running, report which ones and suggest `make up` or `make up-all`.

### `repo` — Explore a sibling Pacto repo

1. Ask which repo or area the user is interested in (e.g., `pacto-app`, `pacto-gov`, `pacto-bot-api`, `pacto-aztec`).
2. Use `Read`, `Glob`, and `Grep` to gather context from the sibling repo under the same base directory.
3. Summarize the repo's purpose, key directories, and how it connects to the dev environment.
4. If the user wants deeper exploration, suggest `/understand` on that repo.

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
- Do not assume the user has Compound Engineering skills installed; always check and offer installation guidance.
