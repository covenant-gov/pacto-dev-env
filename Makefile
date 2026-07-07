# Pacto local development environment
#
# Default stack: nostr-relay + anvil (anvil builds locally on first run).
# Optional profiles: aztec, bunker, seed, full (aztec + bunker + seed), debug.
#
# Generate real bunker secrets in `.env` before using the `bunker` or `full`
# profiles. See `.env.example` for the template.

.PHONY: help up up-all down seed pull build-anvil reset logs check config ensure-sibling-repos

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

down: ## Stop all services and remove containers for all profiles
	docker compose --profile full --profile aztec --profile bunker --profile seed --profile debug down --remove-orphans

pull: ## Pull prebuilt images for relay, aztec, bunker, and backing services
	docker compose pull nostr-relay aztec-sandbox nip46-bunker nip46-bunker-db nip46-bunker-redis

build-anvil: ## Build the local Anvil/Foundry image
	docker compose build anvil

reset: ## Stop all services and remove containers, networks, and data volumes
	docker compose --profile full --profile aztec --profile bunker --profile seed --profile debug down -v --remove-orphans
	rm -rf ./data

logs: ## Follow logs for all running services
	docker compose logs -f

check: ## Verify the running stack is healthy and reachable
	@./scripts/verify-stack.sh

config: ## Generate pacto-bot-api.toml if missing
	@./scripts/init-pacto-bot-api-config.sh
