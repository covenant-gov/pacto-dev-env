# Project workflows

All workflows assume the default Docker services are running:

```bash
cd pacto-dev-env
make up
```

For the full stack (Aztec, bunker, and seed), use `make up-all` instead.

## Build and run `pacto-app`

```bash
cd ~/src/covenant-gov/pacto-app
pnpm install
pnpm run tauri:dev
```

First build downloads and compiles many Rust crates — expect several minutes.

To run just the frontend in a browser:

```bash
pnpm dev
```

### Connect `pacto-app` to the local EVM chain

1. Start the dev services: `cd pacto-dev-env && make up`.
2. In `pacto-app`, open **Settings → Wallet / Network**.
3. Add a custom EVM network:
   - Name: `Pacto Local`
   - RPC URL: `http://localhost:8545`
   - Chain ID: `31337`
   - Currency symbol: `ETH`
4. Import the default Anvil private key for a test account:
   - Account #0 key: `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`
   - **Never use this key outside of local development.**

### Common `pacto-app` build fixes

| Error | Fix |
|-------|-----|
| `webkit2gtk-4.1` not found | `sudo apt install libwebkit2gtk-4.1-dev` |
| `openssl-sys` build fails | `sudo apt install libssl-dev pkg-config` |
| `bindgen` errors | `sudo apt install clang libclang-dev` |
| Vulkan errors on Linux | `sudo apt install libvulkan-dev` |
| macOS `cc` / linker not found | `xcode-select --install` |
| macOS OpenSSL errors | `brew install openssl@3 pkg-config` and export `PKG_CONFIG_PATH` |

## Work on Solidity contracts

```bash
cd ~/src/covenant-gov/pacto-gov
forge install
forge build
forge test
```

Deploy against the local Anvil node:

```bash
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

Use the same RPC and key for `pacto-squad-sponsor` and `delegated-security-manager`.

### Make `pacto-app` use freshly deployed contracts

After running the deploy script, note the printed contract addresses. Then:

1. Find the contract-address config file in `pacto-app` (often under `src-tauri/src/evm/contracts/` or `.env.local`).
2. Update the fields for `PactoGov`, `SquadSponsor`, or `DelegatedSecurityManager` to the addresses from the deploy output.
3. Restart `pnpm run tauri:dev` if the values are read only at Tauri startup.

If the app does not expose a config file, search the Rust source for the current contract address constants and replace them temporarily for local testing — but **do not commit hardcoded local addresses**.

## Work on `pacto-aztec`

Start the Aztec profile:

```bash
cd pacto-dev-env
make up-all          # or: docker compose --profile aztec up -d --build
```

Then follow the Aztec project's own README:

```bash
cd ~/src/covenant-gov/pacto-aztec
pnpm install
pnpm compile   # compiles Noir contracts
pnpm test      # runs tests against the sandbox
```

The Aztec RPC is at `http://localhost:8080`.

## Work on `nostr-k-derivs`

```bash
cd ~/src/covenant-gov/nostr-k-derivs
cargo build
cargo test
```

## Recommended daily workflow

1. Start Docker services: `cd pacto-dev-env && make up`.
2. If working on Aztec, use `make up-all` or run `docker compose --profile aztec up -d --build`.
3. If working on governance contracts, run `make seed` to deploy the Pacto governance system to Anvil and read addresses from `./data/deployments/31337/full-system.json`.
4. In one terminal, run `pacto-app`: `cd pacto-app && pnpm run tauri:dev`.
5. Iterate. Re-run `cargo test`, `forge test`, or `pnpm test` as appropriate.
