# Pacto local development environment
#
# Default stack: nostr-relay + anvil (anvil builds locally on first run).
# Optional profiles: aztec, bunker, seed, full (aztec + bunker + seed), debug.
#
# Generate real bunker secrets in `.env` before using the `bunker` or `full`
# profiles. See `.env.example` for the template.

.PHONY: up up-all down seed pull build-anvil reset logs

up:
	docker compose up -d --build

up-all:
	docker compose --profile full up -d --build

seed:
	docker compose --profile seed run --rm seed

down:
	docker compose --profile full --profile aztec --profile bunker --profile seed --profile debug down --remove-orphans

pull:
	docker compose pull nostr-relay aztec-sandbox nip46-bunker nip46-bunker-db nip46-bunker-redis

build-anvil:
	docker compose build anvil

reset:
	docker compose --profile full --profile aztec --profile bunker --profile seed --profile debug down -v --remove-orphans
	rm -rf ./data

logs:
	docker compose logs -f
