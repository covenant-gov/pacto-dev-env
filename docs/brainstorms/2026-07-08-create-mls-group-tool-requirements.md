---
date: 2026-07-08
topic: create-mls-group-tool
---

# Headless MLS group creation tool

> **Status (2026-07-09): superseded.** This document described a standalone
> `create-mls-group` Rust binary. The shipped implementation is daemon-backed
> (`pacto-bot-admin mls-group`) and is documented in
> [`../pacto-bot-api/docs/plans/2026-07-09-001-feat-daemon-backed-mls-group-admin-plan.md`](../pacto-bot-api/docs/plans/2026-07-09-001-feat-daemon-backed-mls-group-admin-plan.md).
> The operator workflow is in `../../AGENTS.md`.

## Summary

A generic headless CLI tool, shipped as part of the `pacto-bot-api` container image, that creates an MLS group or invites a bot to an existing group. The caller supplies the bot npub, a group name, and a creator nsec. The tool prints the hex-encoded MLS group wire ID to STDOUT and persists group state in a local file inside `pacto-dev-env` so repeated runs are idempotent. `pacto-dev-env` invokes the tool via `docker compose exec pacto-bot-api` from a wrapper script.

## Problem Frame

The only production path for creating an MLS group for Pacto bots is through the Pacto desktop app. This blocks headless local development, CI workflows, and any setup where a developer wants to spin up a squad chat without running a GUI. A command-line tool that reuses the same MLS primitives as `pacto-bot-api`'s test support code removes that dependency and lets developers hand the group ID directly to their bot code.

## Key Decisions

- **Tool placement.** The Rust binary lives in the `pacto-bot-api` repository as a new `pacto-bot-utils` crate, starting with a `create-mls-group` binary. The `pacto-bot-api` Docker image includes the binary so `pacto-dev-env` does not need its own Rust toolchain.
- **Invocation from `pacto-dev-env`.** `pacto-dev-env` provides a `make create-mls-group` target and a `scripts/create-mls-group.sh` wrapper that invokes the binary via `docker compose exec pacto-bot-api`.
- **State file location.** The local state file lives in `pacto-dev-env` at `data/deployments/31337/.mls-groups.json`. The `pacto-bot-api` container mounts `./data/deployments:/data/deployments` so the default `--state-file` path works inside the container.
- **Generic bot input.** The caller passes the bot npub, not a bot id. The tool works for any bot that publishes a KeyPackage on the relay, not just `bosun`.
- **Group name as the idempotency key for the group, group name + bot npub for the invitation.** A named group is created once; subsequent runs with the same group name re-open the existing group, and runs with a different bot npub invite that bot into the same group.
- **Creator identity supplied every run, with safer defaults.** The caller supplies the creator nsec via `PACTO_MLS_CREATOR_NSEC`, `--nsec-file`, or `--nsec` on every invocation. The tool does not persist the nsec; the local JSON state only records the derived creator npub, group ID, and invited bots. The MLS engine uses a separate persistent SQLite database for group state.
- **STDOUT is the primary output.** The group wire ID is printed to STDOUT. The local state file is an implementation detail for idempotency, not the handoff artifact the caller consumes.
- **Local state over relay query, backed by persistent MLS storage.** The tool persists a shared JSON state file so it can reliably find the group ID and invited bots. It also persists the MLS engine's SQLite database in the same directory so it can re-open the group and add new members across runs.

## Requirements

- R1. The CLI accepts the following arguments:
  - `--bot-npub` (required) — the public key of the bot to invite
  - `--group-name` (required) — the human-readable name used as the group idempotency key
  - One of `--nsec`, `PACTO_MLS_CREATOR_NSEC` environment variable, or `--nsec-file` (required) — the creator's Nostr secret key, used for the MLS identity. The `--nsec` flag is supported for local dev convenience but exposes the secret to process lists and shell history.
  - `--relay` (optional, default `ws://nostr-relay:8080` inside the container) — the Nostr relay URL
  - `--state-file` (optional, default `/data/deployments/31337/.mls-groups.json` inside the container) — path to the JSON metadata file
  - `--mls-db` (optional, default `/data/deployments/31337/.mls-creator.db` inside the container) — path to the persistent SQLite database used by the MLS engine
- R2. The tool derives the creator MLS identity from the supplied nsec. The nsec is loaded into a `SecretString` and zeroized after use.
- R3. The tool connects to the specified relay and waits for the bot's KeyPackage (`kind:443`) to appear before creating a group or generating an invitation.
- R4. If no group exists for the given `--group-name` in the state file, the tool creates a new MLS group, invites the bot as the initial member, and publishes the Welcome as a `kind:1059` gift-wrap addressed to the bot.
- R5. If a group already exists for the given `--group-name`, the tool validates that the supplied nsec derives the same creator npub stored in the state file; if not, it exits with an error. This is a deliberate safety check: the original creator must be present to add members to the group.
- R6. If the bot is not already a member of the existing group, the tool fetches the bot's KeyPackage, generates a Welcome, and publishes it as a `kind:1059` gift-wrap.
- R7. If the bot is already a member of the existing group, the tool does not publish a new Welcome.
- R8. On every successful run, the tool prints the hex-encoded MLS group wire ID (`h` tag value) to STDOUT.
- R9. The tool updates the local state file to record the group name, group ID, creator npub, relay, and the list of invited bot npubs.
- R10. The tool is idempotent: running with the same `--group-name` and `--bot-npub` returns the same group ID without duplicating the bot membership.
- R11. The tool returns a non-zero exit code and prints a concise error message when the relay is unreachable, the bot KeyPackage is not found after a timeout, the creator identity is invalid, the supplied creator identity does not match the stored creator for an existing group, or the state file is corrupted or malformed.

## Key Flows

- F1. Create a new group and invite the first bot
  - **Trigger:** `--group-name` does not exist in the state file.
  - **Steps:** Wait for bot KeyPackage → create MLS group → publish Welcome gift-wrap → update state file → print group ID.
  - **Outcome:** A new group exists on the relay and the bot is a member.

- F2. Invite a second bot to an existing group
  - **Trigger:** `--group-name` exists in the state file but `--bot-npub` is not in the invited list.
  - **Steps:** Re-open existing group from state → wait for new bot KeyPackage → publish Welcome gift-wrap → update state file → print group ID.
  - **Outcome:** Both bots are members of the same group.

- F3. Re-run for an already-invited bot
  - **Trigger:** `--group-name` exists and `--bot-npub` is already in the invited list.
  - **Steps:** Read state file → print stored group ID.
  - **Outcome:** No network or MLS mutation occurs.

## Acceptance Examples

- AE1. First run: `create-mls-group --bot-npub npub1... --group-name local-dev-squad --nsec nsec1...` creates a group, prints a 64-character hex group ID, and exits `0`.
- AE2. Second run with the same `--group-name` and `--bot-npub`: prints the same group ID and exits `0` without publishing a new Welcome.
- AE3. Third run with the same `--group-name` and a different `--bot-npub`: prints the same group ID, publishes a Welcome to the new bot, and exits `0`.
- AE4. Run with a different `--group-name`: creates a second group with a different group ID and exits `0`.

## Scope Boundaries

- Extending `make seed-squad` to auto-create an MLS group is not in scope.
- Inviting multiple bots in a single invocation is not in scope; one bot per invocation.
- Auto-populating `.env` files in `pacto-governance-bots` or other sibling repos is not in scope.
- Persistent creator identity management is not in scope; the caller must supply `--nsec` every run.

## Dependencies / Assumptions

- A Nostr relay is running and reachable at the URL provided by `--relay`.
- The target bot has already published a `kind:443` KeyPackage on the relay.
- The bot's daemon configuration (e.g., `pacto-bot-api.toml`) has the capabilities required to accept group invites and send group messages.
- The tool uses the same `mdk-core` / `mdk-sqlite-storage` revision as `pacto-bot-api`.
- The canonical reference implementation is `pacto-bot-api/tests/support/mock_mls_peer.rs`.
