#!/usr/bin/env bash
set -euo pipefail

# Ensure locally-trusted TLS certificates are available for Caddy.
#
# This script is run automatically by `make up` and `make up-all`. It is
# idempotent:
#
# - If mkcert-generated certificates already exist, it keeps using them.
# - If mkcert is installed, it generates certificates and configures Caddy to
#   use them.
# - If mkcert is not installed, it configures Caddy to use its internal
#   self-signed CA and prints a warning.
#
# The script always exits 0 so `make up` does not fail when mkcert is absent.
# To trust the mkcert CA in browsers, run `mkcert -install` after generating
# certificates.

cd "$(dirname "$0")/.."

CERT_DIR="data/certs"
CERT_FILE="$CERT_DIR/localhost.pem"
KEY_FILE="$CERT_DIR/localhost-key.pem"

write_internal_ca_caddyfile() {
  cat > Caddyfile <<'EOF'
{
	# Use Caddy's internal CA for a self-signed TLS cert. This requires no
	# external tooling, but clients must skip verification or trust the cert.
	# To switch to a locally-trusted mkcert cert, install mkcert and run:
	#   scripts/generate-local-certs.sh
}

localhost:8443 {
	bind 0.0.0.0

	tls internal

	reverse_proxy nostr-relay:8080 {
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-Proto {scheme}
	}

	log {
		output stderr
	}
}

localhost:8444 {
	bind 0.0.0.0

	tls internal

	reverse_proxy anvil:8545 {
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-Proto {scheme}
	}

	log {
		output stderr
	}
}

localhost:8445 {
	bind 0.0.0.0

	tls internal

	reverse_proxy aztec-sandbox:8080 {
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-Proto {scheme}
	}

	log {
		output stderr
	}
}

localhost:8446 {
	bind 0.0.0.0

	tls internal

	reverse_proxy nip46-bunker:3000 {
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-Proto {scheme}
	}

	log {
		output stderr
	}
}
EOF
}

write_mkcert_caddyfile() {
  cat > Caddyfile <<'EOF'
{
	# Use a locally-trusted mkcert certificate for all TLS sites.
}

localhost:8443 {
	bind 0.0.0.0

	tls /data/certs/localhost.pem /data/certs/localhost-key.pem

	reverse_proxy nostr-relay:8080 {
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-Proto {scheme}
	}

	log {
		output stderr
	}
}

localhost:8444 {
	bind 0.0.0.0

	tls /data/certs/localhost.pem /data/certs/localhost-key.pem

	reverse_proxy anvil:8545 {
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-Proto {scheme}
	}

	log {
		output stderr
	}
}

localhost:8445 {
	bind 0.0.0.0

	tls /data/certs/localhost.pem /data/certs/localhost-key.pem

	reverse_proxy aztec-sandbox:8080 {
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-Proto {scheme}
	}

	log {
		output stderr
	}
}

localhost:8446 {
	bind 0.0.0.0

	tls /data/certs/localhost.pem /data/certs/localhost-key.pem

	reverse_proxy nip46-bunker:3000 {
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-Proto {scheme}
	}

	log {
		output stderr
	}
}
EOF
}

ensure_cert_dir_writable() {
  if [ -d "$CERT_DIR" ] && [ ! -w "$CERT_DIR" ]; then
    echo "Cert directory $CERT_DIR is not writable (likely owned by root from a Docker run)."
    echo "Fixing ownership with a temporary Docker container..."
    docker run --rm -v "$(pwd):/host" --workdir /host alpine:latest \
      chown -R "$(id -u):$(id -g)" "$CERT_DIR" 2>/dev/null || true
  fi
}

if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
  ensure_cert_dir_writable
  if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    echo "Local TLS certificates already present in $CERT_DIR."
    write_mkcert_caddyfile
    exit 0
  fi
fi

if ! command -v mkcert >/dev/null 2>&1; then
  echo "mkcert is not installed. Caddy will use its internal self-signed CA."
  echo "Install mkcert for locally-trusted certificates:"
  echo "  Ubuntu/Debian: sudo apt install mkcert libnss3-tools"
  echo "  macOS:         brew install mkcert"
  echo "  Other:         see https://github.com/FiloSottile/mkcert#installation"
  write_internal_ca_caddyfile
  exit 0
fi

ensure_cert_dir_writable
mkdir -p "$CERT_DIR"
if mkcert \
  -cert-file "$CERT_FILE" \
  -key-file "$KEY_FILE" \
  localhost 127.0.0.1 ::1; then
  write_mkcert_caddyfile
  echo "Generated local TLS certificates in $CERT_DIR."
  echo "Trust the CA in browsers with: mkcert -install"
else
  echo "mkcert failed. Caddy will use its internal self-signed CA."
  write_internal_ca_caddyfile
fi
