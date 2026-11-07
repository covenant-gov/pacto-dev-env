# Digest verified via `crane digest` (multi-arch index) on 2026-11-07.
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852

ENV DEBIAN_FRONTEND=noninteractive

# Bare minimum to bootstrap the script
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl ca-certificates sudo && \
    rm -rf /var/lib/apt/lists/*

# Create a non-root user with passwordless sudo (so run_privileged can use sudo)
RUN useradd -m -s /bin/bash tester && \
    echo "tester ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/tester && \
    chmod 0440 /etc/sudoers.d/tester

USER tester
WORKDIR /home/tester/pacto-dev-env

COPY --chown=tester:tester setup-ubuntu-lts.sh .
COPY --chown=tester:tester README.md .
COPY --chown=tester:tester docker ./docker

CMD ["bash", "./setup-ubuntu-lts.sh"]
