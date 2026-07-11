# Exposing Pacto dev services over Tailscale

By default the Pacto dev environment binds Anvil (`http://localhost:8545`) and the
Nostr relay (`ws://localhost:7000`) to the host loopback interface only. This
keeps them off the public internet, but it also means they are not reachable from
other devices on your Tailscale tailnet.

This repository provides a small helper that exposes the two default services
over Tailscale without changing the Docker Compose bindings.

## How it works

`make tailscale-serve-up` runs two `tailscale serve` commands on the host:

- `tailscale serve --https=8545 http://localhost:8545` proxies the Anvil EVM RPC
- `tailscale serve --https=7001 http://localhost:7000` proxies the Nostr relay

Tailscale terminates TLS using your tailnet certificate, so the remote client
does not need to trust the local Caddy/mkcert certificate. The Caddy TLS
reverse proxy is bypassed entirely; traffic goes from Tailscale straight to the
plain HTTP/WebSocket ports published by Docker Compose.

## Requirements

- A running Pacto dev stack (`make up`)
- Tailscale installed, logged in, and running on the host
- MagicDNS + HTTPS certificates enabled in your tailnet

## Commands

```bash
# Expose Anvil and the Nostr relay to your tailnet
make tailscale-serve-up

# Check the configured endpoints
make tailscale-serve-status

# Stop exposing them
make tailscale-serve-down
```

You can also run the script directly:

```bash
./scripts/tailscale-serve.sh start
./scripts/tailscale-serve.sh status
./scripts/tailscale-serve.sh stop
./scripts/tailscale-serve.sh env   # print the Pacto env block
```

## Configure the Pacto app

After running `make tailscale-serve-up`, the output prints an env block such as:

```bash
export PACTO_RPC_URL=https://myhost.tailnet-name.ts.net:8545
export PACTO_RELAY_URL=wss://myhost.tailnet-name.ts.net:7001
export PACTO_CHAIN_ID=31337
```

Use those values on the remote tailnet device.

## Custom ports

To use different Tailscale ports, set environment variables before running the
script or make target:

```bash
TAILSCALE_EVM_PORT=18545 TAILSCALE_RELAY_PORT=17001 make tailscale-serve-up
```

## Security notes

- Anvil in this dev environment uses a well-known private key and has no
  authentication.
- The Nostr relay is open by design.
- Only expose these services over your private tailnet. Do not use Tailscale
  Funnel or expose them to the public internet.

## Troubleshooting

- **"tailscale is not installed"** — Install the Tailscale client and run
  `tailscale up`.
- **Empty hostname in the env block** — Run `tailscale status` and substitute
  the machine name or Tailscale IP manually.
- **Port already in use** — The Caddy container binds `127.0.0.1:7001`, but
  Tailscale binds on the tailnet interface. They are different sockets and do
  not conflict. If you see a conflict, pick a different port with
  `TAILSCALE_RELAY_PORT`.
