#!/usr/bin/env bash
set -euo pipefail

# Generate pacto-bot-api.toml if it does not exist.
#
# The daemon requires a config file, but the TOML can reference environment
# variables for secrets. This script creates a minimal safe config so `make up`
# works out of the box. If PACTO_BOT_NSEC is set, a default bot identity is
# included; otherwise a daemon-only config is created and the user can add bots
# later with `pacto-bot-admin`.

CONFIG_FILE="pacto-bot-api.toml"

if [ -f "$CONFIG_FILE" ]; then
  exit 0
fi

if [ -d "$CONFIG_FILE" ]; then
  # Docker Compose creates this as a directory when the file is missing and a
  # host mount is declared. Remove the bogus directory so we can create a file.
  echo "Removing bogus directory $CONFIG_FILE..."
  rm -rf "$CONFIG_FILE"
fi

echo "Generating $CONFIG_FILE..."

cat > "$CONFIG_FILE" <<EOF
[daemon]
data_dir = "/var/lib/pacto-bot-api"
socket_path = "/var/lib/pacto-bot-api/pacto-bot-api.sock"

EOF

if [ -n "${PACTO_BOT_NSEC:-}" ] && [ -n "${PACTO_BOT_NPUB:-}" ]; then
  cat >> "$CONFIG_FILE" <<EOF
[[bots]]
id = "default"
npub = "\${PACTO_BOT_NPUB}"
signing = { backend = "nsec", nsec = "\${PACTO_BOT_NSEC}" }
relays = ["ws://nostr-relay:8080"]
capabilities = ["ReadMessages", "SendMessages"]

EOF
  echo "Added default bot identity using PACTO_BOT_NSEC and PACTO_BOT_NPUB."
else
  echo "No PACTO_BOT_NSEC/PACTO_BOT_NPUB set; generated a minimal daemon-only config."
  echo "Add bot identities later with: pacto-bot-admin new <name> --backend nsec --relays ws://localhost:7000 >> $CONFIG_FILE"
fi

chmod 600 "$CONFIG_FILE"
