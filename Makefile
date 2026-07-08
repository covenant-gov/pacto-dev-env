# Pacto local development environment
#
# Default stack: nostr-relay + anvil (anvil builds locally on first run).
# Optional profiles: aztec, bunker, seed, full (aztec + bunker + seed), debug.
#
# Generate real bunker secrets in `.env` before using the `bunker` or `full`
# profiles. See `.env.example` for the template.

.PHONY: help up up-all down seed seed-squad pull build-anvil reset logs check check-env config ensure-sibling-repos dev verify-squad

help: ## Show this help message and all available targets
	@awk 'BEGIN {FS = ":.*?##"; printf "\nPacto local development environment commands:\n\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

up: config ## Start the default stack (nostr-relay + anvil + pacto-bot-api)
	docker compose up -d --build

ensure-sibling-repos: ## Ensure required sibling repositories (e.g. pacto-gov) are cloned
	@./scripts/ensure-sibling-repos.sh $(if $(YES),--yes)

up-all: config ensure-sibling-repos ## Start the full stack (default + aztec + bunker + seed)
	docker compose --profile full up -d --build

seed: ensure-sibling-repos ## Deploy Pacto governance contracts to Anvil (one-shot)
	docker compose --profile seed run --rm seed

seed-squad: ## Deploy a Nave Pirata squad to Anvil (identities + on-chain crew bootstrap)
	@./scripts/seed-squad.sh

dev: ## One-shot: pull images, start default stack, optional dev bot, seed contracts, print next steps
	@$(MAKE) pull
	@$(MAKE) up
	@$(MAKE) seed
	@echo
	@echo "Default stack is up and governance contracts are seeded (if not already present)."
	@if [ "${PACTO_CREATE_DEV_BOT:-0}" = "1" ]; then \
		echo "Dev bot creation was requested via PACTO_CREATE_DEV_BOT=1."; \
		echo "The config script already appended a 'dev' bot identity if secrets were set."; \
	else \
		echo "No dev bot requested. Set PACTO_CREATE_DEV_BOT=1 (with PACTO_BOT_NSEC/PACTO_BOT_NPUB) to create one."; \
	fi
	@echo
	@echo "Next steps:"
	@echo "  1. Create captain/candidate identities with pacto-bot-admin, or run:"
	@echo "       PACTO_AUTO_CREATE_SQUAD_IDENTITIES=1 make seed-squad"
	@echo "       to let the script create them inside the pacto-bot-api container."
	@echo "  2. If you created them manually, export PACTO_SQUAD_CAPTAIN_NPUB and"
	@echo "     PACTO_SQUAD_CANDIDATE_NPUB, then run:"
	@echo "       make seed-squad"
	@echo "  3. In pacto-governance-bots, generate bots/bosun/.env and start the bot:"
	@echo "       make env"
	@echo "       docker compose up -d"
	@echo "  4. Verify the integration with: make health-check (in pacto-governance-bots)"
	@echo
	@echo "Quick checks:"
	@echo "  cast block-number --rpc-url http://localhost:8545"
	@echo "  docker compose exec pacto-bot-api test -S /var/lib/pacto-bot-api/pacto-bot-api.sock && echo 'daemon socket ready'"
	@echo "  curl -s http://localhost:7000 | head -5"

down: ## Stop all services and remove containers for all profiles
	docker compose --profile full --profile aztec --profile bunker --profile seed --profile debug down --remove-orphans

pull: ## Pull prebuilt images for relay, aztec, bunker, and backing services
	docker compose pull nostr-relay aztec-sandbox nip46-bunker nip46-bunker-db nip46-bunker-redis

build-anvil: ## Build the local Anvil/Foundry image
	docker compose build anvil

reset: ## Stop all services and remove containers, networks, and data volumes
	docker compose --profile full --profile aztec --profile bunker --profile seed --profile debug down -v --remove-orphans
	rm -rf ./data 2>/dev/null || docker run --rm -v "$(CURDIR):/host" --workdir /host alpine:latest rm -rf ./data

logs: ## Follow logs for all running services
	docker compose logs -f

check-env: ## Verify the host environment has the required tools installed
	@./scripts/verify-env.sh

check: check-env ## Verify the host environment and the running stack
	@./scripts/verify-stack.sh

config: ## Generate pacto-bot-api.toml if missing
	@./scripts/init-pacto-bot-api-config.sh

verify-squad: ## Gather on-chain debug info for the seeded squad (registry, Safe, governance, members)
	@./scripts/verify-squad.sh
