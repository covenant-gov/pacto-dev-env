# Invite-first probe findings

Result of the zero-code probe that the dev-world design rests on: can a bot create a squad, invite a stock debug build's identity, and have that identity end up in a populated squad — without any MLS store copy or bundle transfer?

Run 2026-08-11 against the local stack (`nostr-relay` + `pacto-bot-api` from this repo) with a `pacto-app` debug build.

## Verdict

**Transport works; the join does not complete.** Every step from squad creation through welcome delivery succeeded on the first attempt. The joiner receives the welcome, decrypts it, and surfaces it in the UI as a pending invite. It cannot then join: accepting the invite fails, and the squad never materializes.

No MLS store copy or transfer was used or needed at any point, so the design's exclusion of bundle transfer stands. The blocker is a defect in the app's accept path, not a flaw in the invite-first premise.

Three findings were filed against `pacto-app`:

| Finding | Effect on dev-world |
|---|---|
| `pacto-app-384.68` (P0) — welcome accept looks up the gift-wrap id in a store keyed by the rumor id | Blocks the welcome-accepted gate outright |
| `pacto-app-384.69` (P1) — the relay websocket compiles in Mozilla roots and never reads the OS trust store | A debug build needs the `local-relay-tls` feature to reach `wss://localhost:7001` |
| `pacto-app-384.67` (P1) — the default user relay list ignores the relay override | The app still reaches production relays from a "local" sandbox |

## Gates for the orchestrator

Each step below produced an observable signal. These are the gates the dev-world orchestrator should assert, in order, rather than sleeping.

1. **Stack ready.** Relay answers NIP-11 on `http://localhost:7002`.
   Use 7002, not 7000, for this check: ControlCenter/AirPlay squats `*:7000` on macOS, so `localhost:7000` can answer 403 from the wrong process entirely. 7002 is a host-tooling endpoint — the sandbox itself connects over `wss://localhost:7001`.

2. **Sandbox authenticated.** `sandbox-handle.json` exists in the sandbox root and carries a non-null `npub`.
   With `PACTO_DEV_LOGIN_MNEMONIC` set, the app boots straight past the PIN gate — the first accessibility snapshot showed the authenticated navbar with zero keyboard or click calls.

3. **Keypackage published.** A kind-443 event authored by the sandbox npub is retrievable from the relay:
   ```
   ["REQ","kp",{"kinds":[443],"authors":["<pubkey hex>"],"limit":1}]
   ```
   The `relays` tag echoes whatever `PACTO_TRUSTED_RELAYS` was set to, which is how you confirm the app advertised the local endpoint rather than a public one.

4. **Keypackage resolvable *by the bot*.** Gate on the bot's own view, not on the relay query above — publication and bot-side resolution are different events. `scripts/create-mls-group.sh` already polls for this and prints `KeyPackage found on relay.`

5. **Squad created and invite sent.** `create-mls-group.sh` prints the group wire id and writes `data/deployments/31337/group-<bot>.json`.

6. **Welcome delivered.** A kind-1059 gift wrap addressed to the sandbox npub appears on the relay.
   Do not treat the event's `created_at` as a delivery time — NIP-59 randomizes it up to two days into the past. The probe's welcome carried a timestamp ~36 hours old and was nonetheless delivered within seconds.

7. **Welcome ingested by the app.** A row appears in the sandbox database:
   ```sql
   SELECT id, chat_id, resolved_at FROM catch_up_entries WHERE kind = 'welcome';
   ```
   `chat_id` equals the group wire id from step 5. This fired live, with no restart, roughly a second after the invite.

8. **Group joined.** `SELECT group_id, name FROM mls_groups;` returns the group, and `resolved_at` on the catch-up row is non-null.
   **This gate currently never passes** — see below.

Steps 9 and 10 (post-join history and DM backlog) were not reachable and remain unverified. They must be generated *after* the join regardless: forward secrecy hides pre-join messages from a new member.

## Why the join fails

`catch_up_entries.source_event_id` stores the **gift-wrap** event id. Verified directly: the stored value matched the kind-1059 event id returned by the relay byte for byte.

`accept_mls_welcome` passes that id to `engine.get_welcome()`, which in `mdk-core` is keyed by `Welcome.id` — the inner rumor id. `Welcome` carries `id` and `wrapper_event_id` as separate fields, and the app's own accept path reads `wrapper_event_id` separately, which confirms the lookup key is not the wrapper id.

So the accept call always returns `Welcome not found`. `mls_groups` stays empty, and because there is no group row to supply a name, the Catch up entry renders as a disabled button showing an ellipsis. Reproduced on two independent runs with fresh identities, with and without a restart.

## Probe methodology notes

Three artifacts cost time and are worth avoiding when reproducing this.

**Use a stable sandbox root.** *(Fixed upstream — kept here because the symptom is misleading.)* `make dev-sandbox` used to mint a new timestamped root on every invocation, so restarting discarded the MLS key store along with the keypackage private key. A welcome issued against the previous run's keypackage then fails with `No matching key package was found in the key store` — which looks like a delivery bug and is not one. The root is now `test_sandbox/<branch-slug>/<persona>` and stable across runs; `PERSONA=<name>` gives a second identity on the same branch for two-client checks. If you see that error again, something is still handing the app a per-run `PACTO_TEST_SANDBOX_ROOT`.

**Relay routing.** The app's gift-wrap subscription runs on the global client pool, which holds the default public relay list and *not* the overridden trusted relay. The probe's welcome was visible only because `bosun` publishes to `wss://jskitty.cat/nostr` as well as the local relay. Until `pacto-app-384.67` lands, a sandbox pointed at the local stack will not see a welcome published solely to that stack — and the sandbox handle will still report only the local endpoint, understating the app's real exposure.

**`mkcert -install` is only half of the TLS fix.** The probe ran with the mkcert CA already in the macOS System keychain, `openssl s_client` reporting `Verify return code: 0 (ok)` and `curl` returning 200 against `https://localhost:7001` — and the app still refused the same endpoint with `invalid peer certificate: UnknownIssuer`. Installing the CA again, or switching between mkcert and `caddy trust`, changes nothing. rustls with `webpki-roots` is a hermetic trust store by design: `tokio-tungstenite` starts from `RootCertStore::empty()` and populates it only from the compiled-in Mozilla list, so `load_native_certs()` is not in the binary and no keychain is ever consulted. Trusting the CA at the OS level is necessary but not sufficient; the debug build also has to carry the `local-relay-tls` feature that adds `rustls-tls-native-roots` alongside the bundled set.
