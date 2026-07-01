# Pacto wrapper around the official multi-arch Aztec CLI image.
# The upstream image's default entrypoint runs a node script directly, which
# complicates Compose commands. This wrapper:
# - Keeps the upstream multi-arch layer intact
# - Adds curl (for healthchecks)
# - Uses a stable ENTRYPOINT so Compose can append subcommands naturally
ARG AZTEC_IMAGE=aztecprotocol/aztec:5.0.0-nightly.20260625
FROM ${AZTEC_IMAGE}

# Silence the harmless x86_64 tcmalloc LD_PRELOAD warning on arm64
ENV LD_PRELOAD=""

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# Use the same node invocation as upstream, but as an explicit entrypoint so
# Compose `command` is parsed by commander as subcommand/flags.
ENTRYPOINT ["node", "--no-warnings", "/usr/src/yarn-project/aztec/dest/bin/index.js"]
CMD ["start", "--local-network", "--port", "8080", "--admin-port", "8880"]
