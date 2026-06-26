# Anvil local testnet for Pacto development
# Builds Foundry from source so it runs natively on any platform Docker supports.
FROM rust:1-bookworm AS builder

ARG FOUNDRY_VERSION=v1.7.1

RUN apt-get update \
    && apt-get install -y --no-install-recommends cmake clang libclang-dev git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch "${FOUNDRY_VERSION}" https://github.com/foundry-rs/foundry.git . \
    && cargo build --release --bin anvil --bin cast --bin forge --bin chisel

# ---
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/target/release/anvil /usr/local/bin/anvil
COPY --from=builder /src/target/release/cast /usr/local/bin/cast
COPY --from=builder /src/target/release/forge /usr/local/bin/forge
COPY --from=builder /src/target/release/chisel /usr/local/bin/chisel

EXPOSE 8545

ENTRYPOINT ["anvil"]
CMD ["--host", "0.0.0.0", "--port", "8545", "--block-time", "2"]
