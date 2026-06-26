# pacto-debug
# Sidecar container with network/WebSocket debugging tools.
# Start with: docker compose --profile debug up -d --build
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dnsutils \
        iputils-ping \
        jq \
        netcat-openbsd \
        postgresql-client \
        redis-tools \
        socat \
    && rm -rf /var/lib/apt/lists/*

ARG WEBSOCAT_VERSION=1.14.0
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
        amd64) asset="websocat.x86_64-unknown-linux-musl" ;; \
        arm64) asset="websocat_max.aarch64-unknown-linux-musl" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/vi/websocat/releases/download/v${WEBSOCAT_VERSION}/${asset}" \
        -o /usr/local/bin/websocat \
    && chmod +x /usr/local/bin/websocat

# Keep the container alive so it can be exec'd into on demand.
CMD ["sleep", "infinity"]
