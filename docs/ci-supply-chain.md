# CI and image supply-chain controls

This repository is a local-dev orchestration layer. It publishes multi-arch
container images to GHCR on `main` / tag / release events and validates host
setup scripts on pull requests. Controls below harden those surfaces without
changing release tags, attestation, or supported `linux/amd64` + `linux/arm64`
platforms.

## What is already in place on `main`

- [`release-images.yml`](../.github/workflows/release-images.yml) pins Docker /
  GitHub Actions to full commit SHAs, scopes the build job to
  `contents: read`, `packages: write`, `attestations: write`, and
  `id-token: write`, and emits build provenance via
  `actions/attest-build-provenance`.
- GHCR publish uses the workflow `GITHUB_TOKEN` (no long-lived registry
  password in repo secrets).

## Hardening added by the supply-chain draft

| Control | Where |
|---|---|
| Workflow-default `permissions: contents: read` | both workflows |
| Job restates write scopes only where needed | `release-images` build job |
| `persist-credentials: false` on every checkout | both workflows |
| Attest Action pinned to peeled commit SHA `e8998f9…` (`v2.4.0`) instead of the annotated `v2` tag object | `release-images` |
| Checkout unified to `actions/checkout` `v6.0.3` (`df4cb1c…`) | both workflows |
| Multi-arch base / upstream image digests (`crane digest`) | Dockerfiles + Caddy in Compose |
| `websocat` sha256 checks (same values in setup + debug image) | `setup-ubuntu-lts.sh`, `docker/debug.Dockerfile` |
| `bunker46` clone pinned to git SHA (no release tags upstream) | `docker/nip46-bunker.Dockerfile` |
| Corepack pnpm pin `10.10.0` (matches bunker image) | `setup-ubuntu-lts.sh` |
| SHA-pin guard script | `scripts/check-actions-pinned.sh` (shellcheck job) |
| Weekly Dependabot for GitHub Actions pins | `.github/dependabot.yml` |

## Explicit non-goals / residuals

- **No CODEOWNERS file** exists on this repo; none was invented.
- Host setup still downloads Rustup / Foundry / NodeSource / Aztec installers
  over HTTPS (`curl | bash` style). CI mitigates blast radius with
  `PACTO_CLONE_REPOS=skip` and `PACTO_SKIP_AZTEC_CLI=1`, but installer trust
  remains a residual for interactive host setup.
- `nip46-bunker` keeps `pnpm install` lifecycle scripts enabled because native
  deps such as `argon2` need them; `prisma generate` stays an explicit build
  step.
- Floating GHCR app images (`ghcr.io/covenant-gov/...:main`) in Compose are
  intentional for local `make up` UX and are not digest-pinned here.
- Digest pins freeze the verified index at refresh time; Dependabot does not
  bump Docker digests automatically—refresh with `crane digest <image>` when
  intentionally upgrading bases.

## Owner prerequisites (YAML alone does not enforce)

- Keep branch protection / rulesets requiring PR review + status checks for
  `Validate setup scripts` (including Shellcheck / pin check) on `main`.
- Review Dependabot Action PRs; prefer full-SHA pins with version comments.
- Do not broaden PR workflow tokens; release write scopes stay on the release
  job only.
- When rotating base images or `bunker46`, re-verify digests/SHAs before merge.
  Do not guess values.

## Trusted publishing note

GHCR + attestations already use GitHub OIDC-style provenance for this repo’s
images. There is no npm/PyPI publish surface here; no token migration is
required for this repository.
