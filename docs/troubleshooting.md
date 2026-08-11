# Troubleshooting

## Docker containers fail to start

- Confirm Docker has enough RAM (12+ GB when running Aztec).
- Check logs: `cd pacto-dev-env && docker compose logs -f`.

## `pacto-app` cannot connect to the local relay

- Verify the relay is listening: `curl -H "Accept: application/nostr+json" http://localhost:7002` returns its NIP-11 document. Use 7002 rather than 7000 — on macOS, ControlCenter/AirPlay squats `*:7000`, so `localhost:7000` may answer `403` from that process instead of the relay.
- Point the sandbox at `wss://localhost:7001` (`PACTO_TRUSTED_RELAYS`), or add it in Pacto settings as a custom relay in `both` mode.

### `invalid peer certificate: UnknownIssuer`

**Installing the CA again will not fix this, and neither will switching between `mkcert -install` and `caddy trust`.** Trusting the local CA at the OS level is necessary but not sufficient, which is what makes this failure so confusing: every other client on the machine works.

You can confirm the OS side is already correct while the app still fails:

```bash
openssl s_client -connect localhost:7001 -servername localhost </dev/null 2>&1 | grep "Verify return code"
# Verify return code: 0 (ok)
curl -o /dev/null -w '%{http_code}\n' https://localhost:7001/
# 200
```

The app's relay websocket resolves through `nostr-sdk` -> `async-wsocket` -> `tokio-tungstenite`, and `async-wsocket` pins that dependency to `rustls-tls-webpki-roots`. rustls with webpki roots is a **hermetic** trust store by design: the store is built from `RootCertStore::empty()` and populated only from the Mozilla root list compiled into the binary. `load_native_certs()` — the function that would read your keychain — is not compiled in, so no OS trust store is ever consulted at runtime.

The fix is therefore a build flag, not a trust command. A debug `pacto-app` build must carry its `local-relay-tls` feature, which additionally enables `rustls-tls-native-roots`. `tokio-tungstenite` builds its root store additively, so the OS store is consulted *alongside* the bundled Mozilla roots and the local CA validates.

Both halves are required:

| Half | How | Symptom if missing |
|---|---|---|
| CA in the OS trust store | `mkcert -install` (or `caddy trust` for Caddy's internal CA) | `UnknownIssuer`, and `openssl`/`curl` fail too |
| App reads the OS trust store | debug build with `local-relay-tls` | `UnknownIssuer`, but `openssl`/`curl` succeed |

The second row is the case almost everyone hits. Release builds intentionally do not enable the feature: it would widen relay TLS trust to every CA the host trusts.

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
