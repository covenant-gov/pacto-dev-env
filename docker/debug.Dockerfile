# pacto-debug
# Sidecar container with network/WebSocket debugging tools.
# Start with: docker compose --profile debug up -d --build
# Base digest verified via `crane digest` (multi-arch index) on 2026-11-07.
FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

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
        amd64) asset="websocat.x86_64-unknown-linux-musl"; checksum="33a80fcbf2313e3c6e816ddafec333c1a04cc34464d4ba4970d938275775a12f" ;; \
        arm64) asset="websocat_max.aarch64-unknown-linux-musl"; checksum="7b554537b7b046caf598a0db4ee95016e4d2899595c71a403d73ff5ad9f0cbed" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/vi/websocat/releases/download/v${WEBSOCAT_VERSION}/${asset}" \
        -o /usr/local/bin/websocat \
    && echo "${checksum}  /usr/local/bin/websocat" | sha256sum -c - \
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


