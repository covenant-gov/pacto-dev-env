---
date: 2026-07-07
topic: dev-env-debug-visualization
---

# Development Environment Debug & Visualization Tools

## What We're Considering

Add a debugging/visualization capability to the `pacto-dev-env` local development environment so contributors can observe Nostr events, EVM contract activity, and related services (`pacto-bot-api`, Aztec sandbox, NIP-46 bunker) while developing.

This repository is a service orchestration layer, so any debugger should integrate with the existing Docker Compose stack rather than run as a separate external tool.

## Existing Tools by Protocol

### Nostr

| Tool | Type | Best For | Limitations |
|---|---|---|---|
| **Nostr Devtools** (fiatjaf) | Chrome extension | Live graph of client-relay WebSocket traffic, subscriptions, filters, events, notices, AUTH | Only works inside browser clients; useless for headless services like `pacto-bot-api` |
| **Nostr Event Monitor** | Web app | Point at relay URLs, filter by kind/author/tags/NIP, live stream or static fetch | No cross-protocol context; would need to be containerized |
| **nak** | CLI | Scripting, `req`, event crafting, negentropy sync; pairs with `jq`/`fx` | Not a visual tool |
| **vnak** | Desktop GUI (Go/Qt) | Visual event crafting, signing, inspection | Workbench, not a continuous monitor |

### EVM

| Tool | Type | Best For | Limitations |
|---|---|---|---|
| **Otterscan** | Self-hosted block explorer | Lightweight, single-node, local Anvil | Smaller feature set than Blockscout |
| **Blockscout** | Self-hosted block explorer | Full-featured EVM explorer | Heavy resource usage; slower startup |
| **cast** (Foundry) | CLI | Blocks, transactions, receipts, traces | Already in the anvil image and debug sidecar; not visual |
| **Tenderly** | SaaS | Production transaction simulation | Paid; not suitable for local dev |

### Aztec

- Aztec sandbox exposes status endpoints (`http://localhost:8080/status`, admin `http://localhost:8880`).
- Check whether an official containerized explorer exists for the current sandbox version.
- Aztec CLI is available via the `aztec-sandbox` service.

### pacto-bot-api / NIP-46 bunker

- No dedicated visualization tool exists today.
- Current observability: container logs and the Unix socket at `/var/lib/pacto-bot-api/pacto-bot-api.sock`.
- Bunker exposes `/api/auth/config` and uses Postgres + Redis; both can be inspected from the `debug` sidecar.

## Current Debug Infrastructure

The repo already provides:

- A `debug` profile sidecar (`docker/debug.Dockerfile`) with `websocat`, `socat`, `curl`, `jq`, `nc`, `psql`, `redis-cli`.
- Healthchecks on all services.
- `make up` / `make up-all` convenience targets.
- Optional profiles (`aztec`, `bunker`, `seed`, `full`, `debug`).

## Proposed Approaches

### Approach A: Add Containerized Protocol-Specific Explorers

Add one or more optional Docker profiles that run standalone debug UIs:

- `debug-nostr`: containerized Nostr Event Monitor or a minimal websocket→SSE→table bridge pointing at `ws://nostr-relay:8080`.
- `debug-evm`: Otterscan (recommended) or Blockscout against `http://anvil:8545`.
- `debug-aztec`: Aztec sandbox explorer if available.

**Pros:**
- No custom application code.
- Fast to stand up; team gets a consistent debug stack.
- Each tool is maintained by its own upstream.

**Cons:**
- Siloed UIs; no cross-protocol correlation.
- Still requires manual mental mapping between a Nostr event and a resulting EVM transaction.

### Approach B: Custom Lightweight Pacto Debug Dashboard

Build a small web service (e.g., Node/Next.js or Python/FastAPI) that:

- Subscribes to `ws://nostr-relay:8080` and displays live events with filtering.
- Polls `http://anvil:8545` for blocks, transactions, and receipts.
- Tails or reads `pacto-bot-api` logs/state.
- Optionally surfaces Aztec and bunker logs/endpoints.
- Presents a timeline/correlation view, e.g., clicking a Nostr event shows the contract transaction(s) it triggered.

**Pros:**
- Purpose-built for this ecosystem.
- Can encode cross-protocol causality (e.g., Nostr event → EVM tx).
- Unified UI for onboarding new contributors.

**Cons:**
- Build and maintenance burden.
- Requires choosing a stack, designing the UI, and adding tests.

### Approach C: Hybrid — Start with A, Add B Only If Needed

Add Otterscan and a Nostr event viewer to the existing debug profile first. If the team repeatedly needs to correlate events across protocols, invest in the custom dashboard later.

**Pros:**
- Immediate value with minimal effort.
- Informs the custom dashboard design with real usage patterns.
- Avoids over-engineering before the need is proven.

**Cons:**
- Cross-protocol correlation remains manual until Phase 2.

## Recommendation

Start with **Approach C**:

1. **Add Otterscan** for the Anvil EVM testnet.
2. **Add a containerized Nostr event viewer** (Nostr Event Monitor or a minimal equivalent) for the local relay.
3. **Invest in a custom Pacto dashboard only after** cross-protocol correlation becomes a recurring pain point.

This keeps the dev env simple and immediately useful without committing to a full custom build.

## Key Decisions to Make

- **EVM explorer**: Otterscan (lightweight, fast) vs. Blockscout (full-featured, heavy)?
- **Nostr viewer**: Reuse Nostr Event Monitor or build a minimal websocket→SSE→table service?
- **Profile structure**: single `debug` profile, or split into `debug-nostr`, `debug-evm`, `debug-aztec`?
- **Cross-protocol correlation**: required now, or a future nice-to-have?
- **Stack for custom dashboard**: if built later, what runtime fits the ecosystem (Node/pnpm, Rust, Python)?

## Open Questions

- Does the current Aztec sandbox release ship a containerized block explorer?
- What observability does `pacto-bot-api` expose beyond logs and the Unix socket? Should it expose metrics or an HTTP status endpoint?
- Should a future debug dashboard live in this repo (`pacto-dev-env`) or in a sibling application repo?
- Are there any security concerns with exposing debug UIs on host ports (e.g., `.env` secrets, relay metadata)?

## Next Steps

- Decide between Approach A, B, or C.
- If proceeding, run `/workflows:plan` to produce implementation steps, file changes, and verification criteria.
