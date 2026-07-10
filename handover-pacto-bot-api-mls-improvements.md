# Handover: pacto-bot-api MLS improvements for pacto-dev-env

> **Target repo:** `pacto-bot-api` (sibling of this repo).  
> **Do not apply these changes in `pacto-dev-env`.** This document is a prompt for the next assignee working in the admin/daemon repository.

## Background

`pacto-dev-env` now wraps `pacto-bot-admin mls-group create` in `scripts/create-mls-group.sh` and exposes it as `make create-mls-group`. The wrapper is working for local development, but it relies on several assumptions and workarounds that belong in the sibling `pacto-bot-api` repository:

1. **Stale published image.** The `ghcr.io/covenant-gov/pacto-bot-api:main` image is periodically stale. The dev-env workaround is to tell users to run `docker compose build pacto-bot-api` when they see an old binary. The right fix is to publish a fresh image on every merge to `main`.

2. **Admin capability requirement.** The daemon command that backs `pacto-bot-admin mls-group create` currently requires the creator bot to have the `Admin` capability. This is heavy-handed for dev-env usage; we have already added `Admin` to `bosun` and MLS capabilities to `captain` in `pacto-dev-env/pacto-bot-api.toml`, but the requirement is surprising and may be worth tightening or documenting in the admin repo.

3. **Recipient KeyPackage requirement.** The daemon returns a generic **`-32004 nostr relay error`** when the recipient has no fresh KeyPackage (kind:443) on the relay. This makes the wrapper hard to debug. The error should be distinct and actionable, e.g. "recipient has no published KeyPackage (kind:443)".

4. **No headless publish-key-package command.** Operators can currently publish a KeyPackage for a bot only by registering a temporary handler, or by letting the desktop app do it. A `pacto-bot-admin publish-key-package <bot-id>` command would let `pacto-dev-env` pre-publish the recipient's KeyPackage before calling `mls-group create`.

5. **Version is opaque for local builds.** `pacto-bot-admin --version` reports `unknown` for locally built binaries, which makes it hard to confirm which git SHA is actually running in the container.

## Proposed changes for `pacto-bot-api` / admin repo

### 1. CI/CD: publish `ghcr.io/covenant-gov/pacto-bot-api:main` on every merge

Ensure the image tagged `:main` is rebuilt and pushed on every merge to `main`. If the current workflow is intentionally manual, document that in the admin repo README and add a note that local dev-env users should run `docker compose build pacto-bot-api` when they encounter an old binary.

### 2. Distinct error message when recipient KeyPackage is missing

Change the error returned by `DaemonError::Nostr` (or the surrounding code) in the daemon methods that back `do_create_mls_group` and `do_invite_to_mls_group`. When the recipient has no KeyPackage (kind:443) on the relay, return a specific, human-readable error instead of the generic `-32004 nostr relay error`. Example:

```text
Recipient <npub> has no published KeyPackage (kind:443) on the relay.
Publish one first with `pacto-bot-admin publish-key-package <bot-id>`.
```

### 3. (Optional) Add `pacto-bot-admin publish-key-package <bot-id>`

Add a new admin subcommand that calls `agent.publish_key_package` internally for the specified bot identity. This lets operators publish a KeyPackage headlessly without registering a temporary handler. If implemented, update `pacto-dev-env/scripts/create-mls-group.sh` to call it before `mls-group create` when the recipient is local.

### 4. Embed git SHA in `pacto-bot-admin --version`

Use a build-time `env!("VERGEN_GIT_SHA")` or `env!("GIT_SHA")` (or `git describe` via build script) so that locally built binaries print a real git SHA instead of `unknown`. This makes stale-image bugs much easier to diagnose.

## Acceptance criteria

The assignee in `pacto-bot-api` should verify:

- [ ] A fresh `ghcr.io/covenant-gov/pacto-bot-api:main` image is published automatically on every merge to `main`, or the manual step is clearly documented.
- [ ] `pacto-bot-admin mls-group create` returns a distinct error when the recipient has no KeyPackage, instead of `-32004 nostr relay error`.
- [ ] If `publish-key-package` is added, `pacto-bot-admin publish-key-package <bot-id>` runs without error and produces a kind:443 event on the relay for the specified bot identity.
- [ ] `pacto-bot-admin --version` prints a real git SHA for local builds, not `unknown`.
- [ ] After `pacto-dev-env` pulls the new image, `make create-mls-group` succeeds when the recipient has a fresh KeyPackage.
- [ ] The dev-env wrapper still works end-to-end: `data/deployments/31337/group-<BOT_ID>.json` is created and the daemon MLS database has a row in `groups` for the owner bot.

## Files in sibling repo to touch

- `src/dispatch.rs` — likely contains `do_create_mls_group` / `do_invite_to_mls_group` and the error path.
- `src/admin.rs` — admin CLI definition; add `publish-key-package` subcommand and wire it to the daemon if implementing it.
- `src/errors.rs` — add or refine the missing-KeyPackage error variant.
- CI workflow files (e.g. `.github/workflows/docker.yml` or `.github/workflows/ci.yml`) — automate `:main` image build/push.
- `Dockerfile` — pass the build git SHA into the image if needed for `--version`.
- `Cargo.toml` — add `vergen` or a `build.rs` dependency if using a build-time SHA.
- `build.rs` — optional, if using vergen/git describe for the version SHA.
- README or admin CLI docs — document the new/error behavior.

## Context from this session

- The current `pacto-dev-env` flow is:
  1. `pacto-bot-admin mls-group create --bot <BOT_ID> --group <GROUP_NAME> --recipient <RECIPIENT_NPUB>` is invoked inside the running `pacto-bot-api` container.
  2. The wrapper captures the printed group wire ID and writes `data/deployments/31337/group-<BOT_ID>.json`.
  3. The wrapper could optionally call `pacto-bot-admin publish-key-package <RECIPIENT>` before step 1 if that command exists.
- The dev-env config already has `bosun` with `Admin` and `captain` with MLS capabilities (`mls_db_path`, `SendGroupMessages`, `ReceiveGroupMessages`, `ManageProfile`).
- `pacto-dev-env` is not going to implement the missing KeyPackage fix or the CI/CD fix; those are out of scope for the dev-env repo and belong in `pacto-bot-api`.
