# Invite-first probe findings

Result of the zero-code probe that the dev-world design rests on: can a bot create a squad, invite a stock debug build's identity, and have that identity end up in a populated squad — without any MLS store copy or bundle transfer?

Run 2026-08-11 against the local stack (`nostr-relay` + `pacto-bot-api` from this repo) with a `pacto-app` debug build.

## Verdict

**Transport works; the join completes at the MLS layer but produces no squad.** Every step from squad creation through welcome delivery succeeded on the first attempt. The joiner receives the welcome, decrypts it, and surfaces it as a pending invite. Accepting it succeeds — and the squad still never appears.

No MLS store copy or transfer was used or needed at any point, so the design's exclusion of bundle transfer stands. **The invite-first premise holds.** What does not hold is the assumption that a joined MLS group is a visible squad.

> **Correction (re-probe, 2026-08-11).** The first pass reported the accept path itself as broken. That was wrong, and the error was in the probe, not the app: it invoked `accept_mls_welcome` by hand with the catch-up entry's `source_event_id`, which is the gift-wrap id. Every real caller passes `welcome.id`. Re-run against a fresh sandbox and a bot-created group, same build:
>
> ```text
> accept_mls_welcome(id      = 137f8b3c…) -> true
> accept_mls_welcome(wrapper = ac78177c…) -> "Welcome not found"
> ```
>
> After the successful accept, `list_mls_groups` contains the group and pending welcomes drops to zero. `pacto-app-384.68` is closed as not-a-bug; the real defect is `pacto-app-384.70`.

Findings filed against `pacto-app`:

| Finding | Effect on dev-world |
|---|---|
| `pacto-app-384.70` (P1) — a joined MLS group is invisible unless a DM invite introduced it | The welcome-accepted gate passes, but AE1's "populated squad" does not follow |
| `pacto-app-384.69` (P1) — the relay websocket compiles in Mozilla roots and never reads the OS trust store | A debug build needs the `local-relay-tls` feature to reach `wss://localhost:7001` — **fixed**, PR #248 |
| `pacto-app-384.67` (P1) — the default user relay list ignores the relay override | The app still reaches production relays from a "local" sandbox — **fixed**, branch `fix/gate-default-relays-behind-override` |
| `pacto-app-384.68` (P0) — welcome accept id-space mismatch | **Withdrawn**: probe error, see the correction above |

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

5. **Squad created and invite sent.** `make invite-squad` prints the group wire id, writes `data/deployments/31337/group-<bot>.json`, and publishes the `squad_invite` DM — printing its event id. Both halves matter: the MLS welcome alone leaves the group invisible.

6. **Welcome delivered.** A kind-1059 gift wrap addressed to the sandbox npub appears on the relay.
   Do not treat the event's `created_at` as a delivery time — NIP-59 randomizes it up to two days into the past. The probe's welcome carried a timestamp ~36 hours old and was nonetheless delivered within seconds.

7. **Welcome ingested by the app.** A row appears in the sandbox database:
   ```sql
   SELECT id, chat_id, resolved_at FROM catch_up_entries WHERE kind = 'welcome';
   ```
   `chat_id` equals the group wire id from step 5. This fired live, with no restart, roughly a second after the invite.

8. **Squad joined and visible.** `SELECT group_id, name FROM mls_groups;` returns the group, `resolved_at` on the catch-up row is non-null, and the squad renders with its default channels.
   Reached by accepting the invite in the app — DMs → Requests → **Accept**. The orchestrator drives that one click over the MCP bridge; there is deliberately no headless auto-accept, because consent is the point of the invite.
   Do not shortcut it by calling `accept_mls_welcome` directly: that joins the MLS group but produces no squad, which is the whole trap described below. If you do call it, pass the welcome's `id` from `list_pending_mls_welcomes` (matched on `nostr_group_id`), never the catch-up row's `source_event_id`.

Steps 9 and 10 (post-join history and DM backlog) are now reachable and remain unverified. They must be generated *after* the join regardless: forward secrecy hides pre-join messages from a new member.

## Why the squad never appears

The join itself is fine. `accept_mls_welcome(welcome.id)` returns `true`, `list_mls_groups` then contains the group, and pending welcomes drops to zero.

What fails is one layer up. Squads are built entirely on the frontend from the **DM invite payload**: `finalizeSquadAfterAnnouncementsWelcome` constructs the squad from an invite's name, member list and default channels, and it is only ever called from the DM accept path. `handleMlsWelcomeAccepted` covers the pending-channel case and otherwise returns — its docstring says "attach channel or ignore unattributed welcomes". A bot-created invite carries no DM, so the accepted group is joined at the MLS layer and orphaned at the product layer. Catch up then renders it as a disabled button with an empty label, because it routes welcome entries to a DM invite that does not exist.

Two ways out, and the choice was a product decision rather than a bug fix — auto-materializing a squad from any accepted welcome means anyone who can resolve your KeyPackage can put a squad in your sidebar, whereas today the DM invite is the visible, refusable step:

- **App-side** (`pacto-app-384.70`): surface bare welcomes as an explicit, refusable join. Left open as product work; the trust boundary above is the reason it is not automatic.
- **Orchestrator-side — chosen and shipped.** `make invite-squad` creates the squad and publishes the real `squad_invite` DM, so the sandbox joins on the app's own tested path. Nothing about app trust behavior changes, which is what a conformance harness wants.

### The invite contract

`parseSquadInviteMessage` (`src/lib/api/nostr.ts`) requires exactly three fields and ignores the rest:

```json
{ "type": "squad_invite", "squadName": "Barbary Coast", "groupId": "<mls group wire id>" }
```

Because the bot creates the group before sending the DM, the welcome is already pending when the invite lands, so `acceptAnnouncementsInvite` takes its fast path — resolve the pending welcome, accept it, materialize the squad — and never needs the consent-claim/admitter round trip.

One app-side change was still required, and it is debug-only: a sandbox identity is not backup-verified, and `requireBackupVerified()` silently no-ops **Accept**. `dev_login` now marks it, since a recipe-derived phrase is public by construction and there is nothing to back up.

### The id trap

`catch_up_entries.source_event_id` stores the **gift-wrap** id, verified byte for byte against the relay's kind-1059 event. `engine.get_welcome()` is keyed by `Welcome.id`, the inner rumor id; `Welcome` carries both as separate fields. Passing the catch-up row's id to `accept_mls_welcome` therefore returns `Welcome not found`. That is a probe hazard, not an app defect: every real caller passes `welcome.id`.

## Probe methodology notes

Three artifacts cost time and are worth avoiding when reproducing this.

**Use a stable sandbox root.** *(Fixed upstream — kept here because the symptom is misleading.)* `make dev-sandbox` used to mint a new timestamped root on every invocation, so restarting discarded the MLS key store along with the keypackage private key. A welcome issued against the previous run's keypackage then fails with `No matching key package was found in the key store` — which looks like a delivery bug and is not one. The root is now `test_sandbox/<branch-slug>/<persona>` and stable across runs; `PERSONA=<name>` gives a second identity on the same branch for two-client checks. If you see that error again, something is still handing the app a per-run `PACTO_TEST_SANDBOX_ROOT`.

**Relay routing.** *(Fixed — `pacto-app-384.67`.)* The app's gift-wrap subscription runs on the global client pool. That pool held the seven public default relays as well as the overridden trusted relay, so a sandbox advertised one local endpoint while holding seven production connections, and the probe's welcome was visible only because `bosun` publishes to `wss://jskitty.cat/nostr` as well as the local relay — the delivery proved nothing about local routing. A set `PACTO_TRUSTED_RELAYS` now suppresses the default list in both the connection set and the relay audit. Re-verify with `get_relays`: it must return exactly the local endpoint.

**`mkcert -install` is only half of the TLS fix.** The probe ran with the mkcert CA already in the macOS System keychain, `openssl s_client` reporting `Verify return code: 0 (ok)` and `curl` returning 200 against `https://localhost:7001` — and the app still refused the same endpoint with `invalid peer certificate: UnknownIssuer`. Installing the CA again, or switching between mkcert and `caddy trust`, changes nothing. rustls with `webpki-roots` is a hermetic trust store by design: `tokio-tungstenite` starts from `RootCertStore::empty()` and populates it only from the compiled-in Mozilla list, so `load_native_certs()` is not in the binary and no keychain is ever consulted. Trusting the CA at the OS level is necessary but not sufficient; the debug build also has to carry the `local-relay-tls` feature that adds `rustls-tls-native-roots` alongside the bundled set.
