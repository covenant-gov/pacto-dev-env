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

ARG NAK_VERSION=0.20.0
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
        amd64) asset="nak-v${NAK_VERSION}-linux-amd64"; checksum="c92c30eb04fb5519cb385f9b5ad10248c961792c936c7a333ef0e895ef5869b9" ;; \
        arm64) asset="nak-v${NAK_VERSION}-linux-arm64"; checksum="0d51103d73dffd30f3cf5d5e2a5d2349b62aa570760bb1140233beab40a46ca9" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/fiatjaf/nak/releases/download/v${NAK_VERSION}/${asset}" \
        -o /usr/local/bin/nak \
    && echo "${checksum}  /usr/local/bin/nak" | sha256sum -c - \
    && chmod +x /usr/local/bin/nak

# Keep the container alive so it can be exec'd into on demand.
CMD ["sleep", "infinity"]


