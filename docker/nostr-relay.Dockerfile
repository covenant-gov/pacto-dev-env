# Nostr relay for Pacto development
# Builds nostr-rs-relay from source so it runs natively on any platform Docker supports.
# Base digests verified via `crane digest` (multi-arch index) on 2026-11-07.
FROM rust:1-bookworm@sha256:e6f2cff35d0f309acf8433b4f05878ed77092602c5065cc81801177da0bb3a9c AS builder

ARG NOSTR_RELAY_VERSION=0.9.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends cmake git libssl-dev pkg-config protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch "${NOSTR_RELAY_VERSION}" https://github.com/scsibug/nostr-rs-relay.git . \
    && cargo build --release

# ---
FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libssl3 \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 relay
WORKDIR /usr/src/app

COPY --from=builder /src/target/release/nostr-rs-relay ./nostr-rs-relay
COPY --from=builder /src/config.toml ./config.toml.example

RUN chown -R relay:relay /usr/src/app
USER relay

EXPOSE 8080

CMD ["./nostr-rs-relay"]
