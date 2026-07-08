#!/usr/bin/env bash
set -euo pipefail

# Generate pacto-bot-api.toml if it does not exist.
#
# The daemon requires a config file, but the TOML can reference environment
# variables for secrets. This script creates a minimal safe config so `make up`
# works out of the box.
#
# Behavior:
#   - If PACTO_CREATE_DEV_BOT=1 and PACTO_BOT_NSEC/PACTO_BOT_NPUB are set, a
#     "dev" bot identity is appended (or ensured present) in the config.
#   - If PACTO_CREATE_DEV_BOT=1 but the secrets are missing, a warning is printed.
#   - Otherwise, if the config is newly created and PACTO_BOT_NSEC/PACTO_BOT_NPUB
#     are set, a "default" bot identity is included.
#   - Otherwise a daemon-only config is created and the user can add bots later
#     with `pacto-bot-admin`.

CONFIG_FILE="pacto-bot-api.toml"
CREATED=0

# If a sibling .env exists (e.g. for the bunker/full profiles), load it so
# host-side `make config` can see PACTO_CREATE_DEV_BOT / PACTO_BOT_* vars.
if [ -f ".env" ]; then
  set -a
  # shellcheck source=/dev/null
  . ".env"
  set +a
fi

if [ -d "$CONFIG_FILE" ]; then
  # Docker Compose creates this as a directory when the file is missing and a
  # host mount is declared. Remove the bogus directory so we can create a file.
  echo "Removing bogus directory $CONFIG_FILE..."
  rm -rf "$CONFIG_FILE"
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Generating $CONFIG_FILE..."

  cat > "$CONFIG_FILE" <<EOF
[daemon]
data_dir = "/var/lib/pacto-bot-api"
socket_path = "/var/lib/pacto-bot-api/pacto-bot-api.sock"

EOF
  CREATED=1
fi

if [ "${PACTO_CREATE_DEV_BOT:-0}" = "1" ]; then
  if [ -n "${PACTO_BOT_NSEC:-}" ] && [ -n "${PACTO_BOT_NPUB:-}" ]; then
    if grep -q '^id = "dev"$' "$CONFIG_FILE" 2>/dev/null; then
      echo "A bot identity named 'dev' is already present in $CONFIG_FILE."
    else
      cat >> "$CONFIG_FILE" <<EOF
[[bots]]
id = "dev"
npub = "\${PACTO_BOT_NPUB}"
signing = { backend = "nsec", nsec = "\${PACTO_BOT_NSEC}" }
relays = ["ws://nostr-relay:8080"]
capabilities = ["ReadMessages", "SendMessages"]

EOF
      echo "Added dev bot identity using PACTO_BOT_NSEC and PACTO_BOT_NPUB."
    fi
  else
    echo "Warning: PACTO_CREATE_DEV_BOT=1 is set but PACTO_BOT_NSEC and PACTO_BOT_NPUB are both required." >&2
    echo "Set both secrets, or unset PACTO_CREATE_DEV_BOT to start with a daemon-only config." >&2
  fi
elif [ "$CREATED" = "1" ]; then
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
fi

chmod 600 "$CONFIG_FILE"
