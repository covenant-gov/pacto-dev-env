# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
- `make check` now displays the running versions of anvil, nostra (nostr-relay), and pacto-bot-api alongside the existing health checks. The pacto-bot-api version is read from its local HTTP `/version` endpoint, so the daemon now starts with `--enable-http` in the default stack.
- Add `docker/debug.Dockerfile` and a `debug` Compose profile with network/WebSocket debugging tools (`websocat`, `socat`, `curl`, `jq`, `nc`, `psql`, `redis-cli`, `ping`, `dig`).
- Install debugging utilities (`socat`, `websocat`, `jq`, `netcat-openbsd`) via the Ubuntu setup script and add a missing `verify_install()` step.
- Add `PACTO_CLONE_REPOS=skip` and `PACTO_SKIP_AZTEC_CLI=1` options to `setup-ubuntu-lts.sh` for non-interactive installs.
- Add GitHub Actions CI workflow (`.github/workflows/validate-setup.yml`) that validates the Ubuntu setup on 24.04/26.04, builds the debug sidecar for `amd64`/`arm64`, and runs `shellcheck`.
- Update `README.md` and `AGENTS.md` with debugging recipes and the new `debug` profile.

# v0.1.0
- Initial release of `pacto-dev-env`: one-shot setup scripts and Docker Compose services for local Pacto ecosystem development.
