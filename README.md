# houselocator-platform

Infraestructura y esquema de base de datos de [HouseLocator](docs/HLD.md):
un sistema personal que scrapea los portales inmobiliarios más importantes
de España, avisa por Telegram de pisos nuevos, y analiza tendencias de
precio. Diseño completo en [`docs/HLD.md`](docs/HLD.md).

Este repo es el orquestador del workspace: contiene el `compose.yaml`, las
migraciones SQL, y los scripts para arrancar todo el stack. Se espera que
viva junto a sus repos hermanos (`houselocator-ingest`, `houselocator-bot`,
...) en la misma carpeta padre.

## Arranque en local

```bash
cp .env.example .env   # rellena POSTGRES_PASSWORD y las claves de Telegram
make bootstrap          # clona los repos hermanos que falten
make up                  # levanta db + migraciones + ingest + bot, todo de una vez
make logs                 # sigue los logs de ingest/bot en vivo
make down                  # para todo
```

Actualmente el sistema solo corre mientras tienes Docker Desktop abierto y
ejecutas `make up` — no hay VPS desplegado todavía (ver
[decisión de hosting en `docs/HLD.md` §6](docs/HLD.md)).

Otros comandos: `make ps` (estado de los contenedores), `make verify`
(smoke test de Postgres+migraciones sin levantar ingest/bot), `make
migrate` (solo aplicar migraciones pendientes).

## Migraciones

Usamos [dbmate](https://github.com/amacneil/dbmate) vía Docker (no hace
falta instalarlo localmente). Migraciones en `db/migrations/`, formato
`<timestamp>_<nombre>.sql` con bloques `-- migrate:up` / `-- migrate:down`.

Nueva migración:

```bash
docker compose run --rm migrate new nombre_de_la_migracion
docker compose run --rm migrate up
```

## Deploy

```bash
HOUSELOCATOR_DEPLOY_HOST=user@vps ./scripts/deploy.sh
```

Ver [`docs/HLD.md`](docs/HLD.md) §6 para la recomendación de hosting (VPS
Hetzner + Tailscale) y el resto de decisiones de arquitectura.

## Grafo de código

`python3 scripts/graphify_export.py .` genera `outputs/graph-export.json`
(imports/docs de este repo). Desde la carpeta padre `houselocator/`,
`python3 scripts/graphify_aggregate.py .` agrega los 3 repos en un grafo
multi-repo con dependencias detectadas entre ellos (mismo patrón que
AeroRoute).
