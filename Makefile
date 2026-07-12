.PHONY: up down restart logs ps verify bootstrap deploy migrate

# Levanta todo el stack local (Postgres + migraciones + ingest + bot) de una vez.
up:
	@test -f .env || (echo "No existe .env — cp .env.example .env y rellénalo." >&2 && exit 1)
	docker compose up -d db
	docker compose run --rm migrate
	docker compose up -d --build ingest bot

# Para todo el stack local.
down:
	docker compose down

restart: down up

# Sigue los logs de ingest y bot en vivo (Ctrl+C para salir, no para nada).
logs:
	docker compose logs -f ingest bot

ps:
	docker compose ps

verify:
	./scripts/verify-local-stack.sh

bootstrap:
	./scripts/bootstrap-workspace.sh

deploy:
	./scripts/deploy.sh

migrate:
	docker compose up -d db
	docker compose run --rm migrate
