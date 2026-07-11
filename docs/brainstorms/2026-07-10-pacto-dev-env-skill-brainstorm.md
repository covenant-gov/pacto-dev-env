---
date: 2026-07-10
topic: pacto-dev-env-skill
---

# Pacto Dev Environment Skill

## What We're Building

A self-bootstrapping Claude Code skill for the Pacto ecosystem. Once installed in any repo (or even an empty directory), the skill can stand up the entire local development environment, clone sibling repositories, start services, and configure the current codebase to connect to the dev stack.

The skill lives in this repository under `skills/pacto-dev-env/SKILL.md` and is distributed via the Vercel skills CLI: `npx skills add covenant-gov/pacto-dev-env`.

## Why This Approach

We want a single, natural-language entry point for Pacto development. A developer should be able to open any Pacto repo and ask Claude to "set up the dev env and connect this app to it" without remembering Make targets, Docker profiles, Caddy ports, or TLS certificate workarounds. Existing scripts like `scripts/pacto-connect.sh` and `make check` already solve most of the pieces; the skill wraps them and adds bootstrapping, cross-repo awareness, and troubleshooting.

## Key Decisions

- **Skill format:** Claude Code skill directory under `skills/pacto-dev-env/SKILL.md`, installed with `npx skills add covenant-gov/pacto-dev-env`.
- **Self-bootstrapping:** If `pacto-dev-env` is not present, the skill clones it to `~/src/covenant-gov/pacto-dev-env` (or `PACTO_DEV_ENV_DIR` if set), then runs the host setup script and starts the stack.
- **Sibling repos:** The skill clones `pacto-app`, `pacto-gov`, `pacto-bot-api`, and `pacto-aztec` when they are missing.
- **Current repo configuration:** The skill detects which Pacto repo it is invoked from and writes the correct environment variables / config files for that repo.
- **Subcommands via arguments:** `setup`, `status`, `connect`, and `troubleshoot ssl`.
- **Invocation control:** `disable-model-invocation: true` because the skill has side effects (cloning, running setup scripts, starting Docker, writing config files).
- **Helper scripts:** Complex logic like platform detection and config file patching lives in `scripts/skill-*.sh` so the SKILL.md stays focused on instructions.

## Open Questions

- Should the skill automatically trust/ignore Caddy's self-signed certificates, or should it prompt the user and document the `mkcert -install` step?
- Should the skill auto-start Docker services, or should it confirm with the user before running `make up`?
- Which sibling repos should be cloned by default? All four, or only the ones relevant to the current repo?
- Should the skill support being invoked from a non-repo directory to create a fresh workspace?

## Next Steps

→ `/workflows:plan` for implementation details.
