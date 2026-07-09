# Troubleshooting

## Docker containers fail to start

- Confirm Docker has enough RAM (12+ GB when running Aztec).
- Check logs: `cd pacto-dev-env && docker compose logs -f`.

## `pacto-app` cannot connect to the local relay

- Verify the relay is listening: `curl http://localhost:7000` should return a relay message.
- In Pacto settings, add `ws://localhost:7000` as a relay.

## Foundry/Anvil deployment fails

- Confirm the Anvil container is running and RPC responds:
  `cast block-number --rpc-url http://localhost:8545`.
- If the recorded factory address is missing after a chain reset, run `make seed` (or `make reseed` / `make reseed-all`) to re-deploy.
- Use the default Anvil private key for local deployments; never commit real keys.

## Aztec sandbox is slow or OOMs

- Increase Docker memory limit to at least 8 GB, preferably 12 GB.
- Stop other containers you are not actively using.

## General notes and caveats

- The `anvil` image is built locally for the host architecture (arm64 on Apple Silicon, x86_64 on Linux) because the GHCR image is not yet public. The `nostr-relay`, `aztec-sandbox`, and `nip46-bunker` images are pulled from GHCR. No `platform: linux/amd64` pinning or Rosetta emulation is required.
- First `make up` will take a few minutes while `anvil` is built from source. Subsequent starts use the cached `pacto-anvil:local` image.
- If Anvil emulation is too slow on an M4 Mac, run `anvil` natively via `foundryup` instead and stop the `anvil` container.
- Aztec's sandbox is the heaviest service. Do not start it unless you are actively working on `pacto-aztec`.
- Private keys should never be committed. The `nsec` signing backend is for local testing only.

## Debugging with the debug sidecar

Host-side debugging tools are installed by the setup scripts: `socat`, `websocat`, `jq`, `curl`, and `cast`.

Start the optional debug sidecar to inspect services from inside the container network:

```bash
docker compose --profile debug up -d --build
docker compose exec debug bash
```

Common recipes:

```bash
# Open a raw WebSocket to the Nostr relay
websocat ws://nostr-relay:8080

# Send a Nostr REQ filter (paste, then hit Enter twice)
websocat ws://nostr-relay:8080
["REQ", "debug-1", {"kinds": [1], "limit": 5}]

# Tap relay traffic between ports
socat -v TCP-LISTEN:7001,fork TCP:nostr-relay:8080

# Check Anvil RPC from inside the container network
curl -fsS -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://anvil:8545 | jq .

# Inspect bunker Postgres
psql postgresql://bunker46:bunker46@nip46-bunker-db:5432/bunker46

# Inspect bunker Redis
redis-cli -h nip46-bunker-redis ping
```
