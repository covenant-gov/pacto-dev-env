#!/usr/bin/env bash
set -euo pipefail

# Generate a locally-trusted TLS certificate for wss://localhost:7001 using
# mkcert (https://github.com/FiloSottile/mkcert). After running this script,
# restart the Caddy sidecar so it picks up the new certificate.

if ! command -v mkcert >/dev/null 2>&1; then
  echo "mkcert is not installed. Install it first:"
  echo "  Ubuntu/Debian: sudo apt install mkcert libnss3-tools"
  echo "  macOS:         brew install mkcert"
  echo "  Other:         see https://github.com/FiloSottile/mkcert#installation"
  exit 1
fi

cd "$(dirname "$0")/.."

mkdir -p data/certs
mkcert \
  -cert-file data/certs/localhost.pem \
  -key-file data/certs/localhost-key.pem \
  localhost 127.0.0.1 ::1

cat > Caddyfile <<'EOF'
localhost:8443 {
  bind 0.0.0.0

  tls /data/certs/localhost.pem /data/certs/localhost-key.pem

  reverse_proxy nostr-relay:8080 {
    header_up Host {host}
    header_up X-Real-IP {remote_host}
  }

  log {
    output stderr
  }
}
EOF

echo "Generated local certs and updated Caddyfile."
echo "Restart the caddy service to use them:"
echo "  docker compose restart caddy"
