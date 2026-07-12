#!/usr/bin/env bash
# Smoke test end-to-end del stack local: levanta Postgres, corre migraciones,
# y comprueba que el esquema quedó creado correctamente.
# Uso: cd houselocator-platform && ./scripts/verify-local-stack.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ ! -f .env ]]; then
  echo "No existe .env — cópialo desde .env.example y rellena POSTGRES_PASSWORD como mínimo." >&2
  exit 1
fi

echo "→ Levantando db + migrate..."
docker compose up -d db
docker compose run --rm migrate

echo "→ Comprobando tablas esperadas..."
set -a; source .env; set +a
EXPECTED_TABLES=(listings listing_price_history listing_events scrape_runs zone_daily_stats search_filters notifications)
for t in "${EXPECTED_TABLES[@]}"; do
  count=$(docker compose exec -T db psql -U "${POSTGRES_USER:-houselocator}" -d "${POSTGRES_DB:-houselocator}" -tAc \
    "SELECT to_regclass('public.${t}') IS NOT NULL;")
  if [[ "${count}" != "t" ]]; then
    echo "✗ Falta la tabla ${t}" >&2
    exit 1
  fi
  echo "✓ ${t}"
done

echo "→ Stack local OK. Para levantar ingest/bot: docker compose up -d ingest bot"
