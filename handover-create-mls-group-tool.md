# Handover: Headless MLS group creation tool for pacto-dev-env

> **Status: done.** The daemon-backed `pacto-bot-admin mls-group` command is
> implemented in `pacto-bot-api` and `pacto-dev-env` exposes it as a single
> Make target. The standalone `create-mls-group` binary described in older
> brainstorm/plan docs has been replaced by the daemon-backed workflow.

## Operator reference

Use `make create-mls-group` from `pacto-dev-env`.

```bash
make create-mls-group BOT_ID=bosun RECIPIENT_NPUB=<captain-npub> GROUP_NAME=local-dev-squad
```

This will validate the creator, publish a KeyPackage for the recipient bot if
needed, poll the relay, create the group, write the artifact to
`data/deployments/31337/group-<BOT_ID>.json`, and print the group wire ID.

See `AGENTS.md` > "Creating an MLS group" for the full workflow, environment
variables, and troubleshooting notes.

## Historical context

- Older brainstorm: `docs/brainstorms/2026-07-08-create-mls-group-tool-requirements.md`
- Older plan: `docs/plans/2026-07-08-001-feat-create-mls-group-tool-plan.md`
- Current plan: `../pacto-bot-api/docs/plans/2026-07-09-001-feat-daemon-backed-mls-group-admin-plan.md`
