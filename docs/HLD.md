# HouseLocator — Plan de arquitectura e implementación

## Contexto

Proyecto personal nuevo: un sistema que scrapea los portales inmobiliarios más
importantes de España (fase 1: Idealista + Fotocasa), avisa por Telegram
cuando aparece un piso nuevo que encaja en los criterios del usuario, permite
ver tendencias de precio por zona, y deja diseñado (sin implementar aún) un
localizador de hipotecas con ofertas bancarias como fase 2.

El usuario pidió explícitamente: (a) que el diseño lo hiciera el modelo Fable
5 antes de implementar con Sonnet, y (b) una estructura **multi-repositorio**,
no un monorepo. El plan siguiente es el resultado de ese diseño (agente Fable
5), revisado y ajustado tras inspeccionar cómo el usuario ya organiza sus
otros proyectos personales en el mismo disco.

**Hallazgo clave de la inspección**: en
`/Volumes/Lexar/Proyectos Personales/` ya existe una convención establecida
(proyecto `AeroRoute`): una carpeta paraguas *sin repo propio* que contiene
varios checkouts git independientes hermanos (`aeroroute-api`,
`aeroroute-contracts`, `aeroroute-platform`, `aeroroute-web`, ...), cada uno
con su propio remoto en GitHub. El repo `aeroroute-platform` hace de
orquestador: contiene `compose.yaml`, `scripts/bootstrap-workspace.sh` (clona
los repos hermanos que falten), `scripts/verify-local-stack.sh` (smoke test
end-to-end), y `docs/` con el diseño (HLD). La carpeta paraguas tiene un
`README.md` local (no publicado) que enlaza a la doc canónica del repo
platform. Hay también un hub de arquitectura en el repo `wiki-personal`
(`wiki/projects/aeroroute.md`).

HouseLocator seguirá **la misma convención estructural** (carpeta paraguas +
repos hermanos + repo `-platform` orquestador + hub en wiki-personal), pero
**sin** la maquinaria específica de AeroRoute que no aplica aquí (SBOM,
validadores ICAO, pipeline de releases): HouseLocator es un proyecto personal
mucho más pequeño y no tiene esos requisitos de dominio/compliance.

Ubicación: `/Volumes/Lexar/Proyectos Personales/houselocator/`

## 1. Repositorios

4 repos en fase 1 (mínimo necesario para separar ciclos de vida distintos:
scraper que se rompe a menudo vs bot estable vs infra), 1 opcional en fase 4,
1 futuro en fase 2. No se crea un repo `-contracts` separado (a diferencia de
AeroRoute): aquí no hace falta una librería de tipos compartida entre
lenguajes — ingest y bot son ambos Python y comparten esquema vía SQL, no vía
paquete.

### 1.1 `houselocator-platform` (repo orquestador, rol de `aeroroute-platform`)
- **Responsabilidad**: fuente única de verdad de infraestructura y esquema de
  BD. `compose.yaml` (Postgres 16 + dbmate + ingest + bot, perfiles opcionales
  para FlareSolverr/web), migraciones SQL (`db/migrations/`), `.env.example`,
  `scripts/bootstrap-workspace.sh` (clona los repos hermanos que falten),
  `scripts/verify-local-stack.sh` (levanta el stack y comprueba salud),
  `scripts/deploy.sh` (deploy al VPS por SSH), `docs/HLD.md` (este diseño,
  versionado), README de entrada del proyecto.
- **Stack**: SQL plano + `dbmate` para migraciones (sin ORM). Docker Compose.
- Es el repo que se clona primero y desde el que se arranca todo.

### 1.2 `houselocator-ingest`
- **Responsabilidad**: scraping de Idealista y Fotocasa, normalización a
  esquema común, detección nuevo/actualizado/eliminado, escritura en
  Postgres, emisión de eventos (tabla outbox), snapshot diario de
  estadísticas de zona, auto-monitorización (canary + alertas de scraper
  roto al chat admin de Telegram).
- **Stack**: Python 3.12 (gestor `uv`), `httpx` + `curl_cffi` (impersonación
  TLS para Idealista), `selectolax` para HTML, `pydantic` v2 para el modelo
  normalizado, `APScheduler` (scheduler in-process), `tenacity` (reintentos),
  `psycopg3` (SQL directo, sin ORM). `pytest` con fixtures HTML/JSON
  congeladas como tests de contrato por portal.
- **Despliegue**: contenedor long-running, `restart: unless-stopped`.

### 1.3 `houselocator-bot`
- **Responsabilidad**: bot de Telegram. Gestión conversacional de filtros de
  búsqueda, consumo de la outbox de eventos, matching filtro↔anuncio, envío
  de alertas con foto, comandos de tendencias con gráficos, canal admin de
  salud del sistema. Handlers modulares por dominio (ya pensado para poder
  añadir el dominio "mortgages" en fase 2 sin reestructurar).
- **Stack**: Python 3.12, `aiogram` 3 (async), `psycopg3`, `matplotlib`
  (genera PNG de tendencias, `sendPhoto`). Long polling (no webhook: sin
  exponer puertos, funciona detrás de NAT/Tailscale).
- **Despliegue**: contenedor long-running en el mismo compose.

### 1.4 `houselocator-web` (fase 4, opcional)
- **Responsabilidad**: dashboard de tendencias más rico que el bot
  (exploración visual: mapas, scatter €/m² vs m², distribuciones).
- **Stack**: Streamlit, lee Postgres con usuario read-only.
- **Despliegue**: contenedor accesible solo vía Tailscale (nunca expuesto a
  internet). Se construye cuando haya ≥3 meses de histórico — antes no
  aporta valor.

### 1.5 `houselocator-mortgages` (fase 2 — solo diseño, sin código todavía)
Ver sección 8.

### Comunicación entre repos
**Postgres compartido + tabla outbox de eventos.** Sin cola de mensajes ni
API REST interna — para un único consumidor (el bot) sería complejidad
gratuita.
- `ingest` escribe `listings` + `listing_events`; `bot` hace polling de
  `listing_events` cada 30s con cursor.
- `bot` escribe `search_filters`/`notifications`; `ingest` **lee**
  `search_filters` para saber qué zonas scrapear (los filtros del usuario
  definen el scope — nunca se scrapea toda España).
- Si algún día hace falta más, la outbox se sustituye por `LISTEN/NOTIFY` o
  una cola, sin tocar el modelo de datos.

## 2. Modelo de datos (`houselocator-platform/db/migrations/001_initial_schema.sql`)

```sql
CREATE TYPE portal AS ENUM ('idealista', 'fotocasa');
CREATE TYPE listing_status AS ENUM ('active', 'delisted');

CREATE TABLE listings (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  portal            portal NOT NULL,
  portal_listing_id text   NOT NULL,
  url               text   NOT NULL,
  title             text,
  price_eur         integer NOT NULL,
  size_m2           integer,
  price_m2          numeric GENERATED ALWAYS AS (price_eur::numeric / NULLIF(size_m2,0)) STORED,
  rooms             smallint,
  bathrooms         smallint,
  floor             text,
  property_type     text,
  city              text NOT NULL,
  zone              text,
  address_raw       text,
  lat               double precision,
  lng               double precision,
  features          jsonb DEFAULT '{}',
  image_urls        jsonb DEFAULT '[]',
  description       text,
  content_hash      text NOT NULL,
  status            listing_status NOT NULL DEFAULT 'active',
  first_seen_at     timestamptz NOT NULL DEFAULT now(),
  last_seen_at      timestamptz NOT NULL DEFAULT now(),
  delisted_at       timestamptz,
  raw               jsonb,
  UNIQUE (portal, portal_listing_id)
);

CREATE TABLE listing_price_history (
  listing_id  bigint REFERENCES listings(id),
  price_eur   integer NOT NULL,
  observed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (listing_id, observed_at)
);

CREATE TABLE listing_events (       -- outbox: ingest escribe, bot consume
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  listing_id bigint REFERENCES listings(id),
  event_type text NOT NULL,         -- new | price_drop | price_increase | delisted
  payload    jsonb DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE scrape_runs (          -- salud del scraper
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  portal portal NOT NULL,
  run_type text NOT NULL,           -- new_scan | full_sweep
  started_at timestamptz, finished_at timestamptz,
  status text NOT NULL,             -- ok | error | blocked | zero_results
  pages_fetched int, listings_found int, new_count int, updated_count int,
  error jsonb
);

CREATE TABLE zone_daily_stats (     -- snapshot diario para tendencias
  city text, zone text, day date,
  median_price_m2 numeric, avg_price_m2 numeric, p25 numeric, p75 numeric,
  active_listings int, new_listings int,
  PRIMARY KEY (city, zone, day)
);

CREATE TABLE search_filters (       -- propiedad del bot
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text NOT NULL, active boolean DEFAULT true,
  city text NOT NULL, zones text[],
  price_min int, price_max int, size_min int, rooms_min int,
  property_types text[], extra jsonb DEFAULT '{}',
  notify_price_drops boolean DEFAULT true,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE notifications (        -- dedupe de alertas
  filter_id bigint, listing_id bigint, event_type text,
  sent_at timestamptz DEFAULT now(),
  PRIMARY KEY (filter_id, listing_id, event_type)
);
```

**Detección nuevo / actualizado / eliminado**:
- **Nuevo**: `(portal, portal_listing_id)` no existe → INSERT + fila en
  `price_history` + evento `new`.
- **Actualizado**: existe y `content_hash` difiere → UPDATE; si cambió el
  precio, fila en `price_history` + evento `price_drop`/`price_increase`.
  Siempre `last_seen_at = now()`.
- **Eliminado/vendido**: solo lo decide el `full_sweep` diario: anuncios
  `active` en scope cuyo `last_seen_at` sea anterior a 2 sweeps completados
  con éxito → `delisted` + evento. Guarda-raíl: si un sweep devuelve 0
  resultados o falla, nunca se marca nada como delisted (evita falsos
  "vendidos" cuando el parser se rompe).

## 3. Diseño del scraper/ingesta (`houselocator-ingest`)

```
src/ingest/
  main.py               # arranca APScheduler + jobs
  scheduler.py          # jobs con jitter aleatorio (±20%, para no parecer cron)
  pipeline.py           # fetch -> parse -> normalize -> upsert -> events
  models.py             # NormalizedListing (pydantic)
  db.py                 # upserts, outbox, scrape_runs
  scopes.py             # lee search_filters activos -> URLs de búsqueda
  portals/
    base.py             # interfaz PortalScraper: fetch_search_page(), parse_cards()
    fotocasa.py         # parsea __NEXT_DATA__ (JSON embebido, robusto)
    idealista.py        # curl_cffi impersonate + parseo HTML selectolax
  antibot.py             # rate limiter token-bucket por portal, sesiones, backoff
  canary.py               # smoke test en vivo + alerta admin si algo se rompe
  stats.py                # job diario que puebla zone_daily_stats
tests/
  fixtures/               # snapshots HTML/JSON reales por portal (tests de contrato)
```

**Dos jobs por portal**:
1. `new_scan` (cada 30–60 min): búsqueda ordenada por "más recientes", 1–3
   páginas por scope. Alimenta las alertas.
2. `full_sweep` (1×/día, madrugada): recorre todas las páginas de cada
   scope, actualiza precios/`last_seen_at`, dispara delisting, luego corre
   `stats.py`.

**Anti-bot por portal**:
- **Fotocasa** (permisivo): `httpx`, headers realistas, 1 req/3–5s. Parsear
  el JSON `__NEXT_DATA__` en vez de selectores CSS (resistente a rediseños).
- **Idealista** (Cloudflare/fingerprinting), estrategia en escalera:
  1. `curl_cffi` con `impersonate="chrome"` + cookies persistidas + 1
     req/8–15s (suele bastar para volumen personal).
  2. Si 403/challenge persistente: FlareSolverr como sidecar en el compose,
     solo para las peticiones bloqueadas.
  3. Último recurso (documentado, no contratado de entrada): proxy
     residencial de pago por GB.
  - Solicitar la API oficial de Idealista (gratuita, ~100 req/mes OAuth)
    como complemento legítimo, aunque insuficiente como fuente principal.
- **Circuit breaker global**: 403/429/captcha → backoff exponencial
  (5min→1h→6h), `status='blocked'` en `scrape_runs`, alerta al chat admin.
- **Reintentos**: `tenacity`, 3 intentos con backoff por página; fallo de
  parseo de una card individual no aborta la página (se loggea con `raw`).

**Cuando el HTML cambia** (pasará):
- Parsers desacoplados vía interfaz `PortalScraper` — arreglar Idealista no
  toca Fotocasa.
- Tests de contrato con fixtures reales congeladas.
- Canary post-run: si `listings_found == 0` donde antes había >0, o >30% de
  cards fallan al parsear → alerta al chat admin ("⚠️ Parser de Idealista
  posiblemente roto").

## 4. Alertas Telegram (`houselocator-bot`)

- `/newfilter`: flujo FSM (ciudad → zonas → precio máx → m² mín →
  habitaciones) → guarda en `search_filters`. `ingest` lo recoge en el
  siguiente ciclo.
- `/filters`, `/pausefilter <id>`, `/delfilter <id>`.
- Solo responde al `TELEGRAM_ALLOWED_USER_ID` configurado (usuario único).
- **Matching**: loop cada 30s → eventos nuevos de la outbox → cruce SQL
  contra filtros activos → `INSERT ... ON CONFLICT DO NOTHING` en
  `notifications` (dedupe) → si insertó, envía alerta.
- **Formato** (`sendPhoto` + caption HTML):
  ```
  🏠 NUEVO · Fotocasa
  Piso en Calle Alcalá, Goya (Madrid)
  💶 315.000 € · 82 m² · 3.841 €/m²
  🛏 3 hab · 🛁 2 baños · 4ª planta, ascensor
  🔎 Filtro: "Goya hasta 350k"
  [Ver anuncio →](url)
  ```
  Para bajada de precio: `📉 BAJADA: 340.000 € → 315.000 € (−7,4%)`.

## 5. Tendencias de precios — bot primero, dashboard después

Comandos del bot con gráficos PNG (matplotlib → `sendPhoto`):
- `/trend <zona> [meses]` → mediana €/m² desde `zone_daily_stats`.
- `/stats <zona>` → mediana/p25/p75 actuales, activos, variación 30/90 días.
- `/history <id|url>` → evolución de precio de un anuncio.
- `/compare <zona1> <zona2>` → dos líneas, mismo gráfico.

`houselocator-web` (Streamlit) queda para fase 4, cuando haya ≥3 meses de
histórico que justifiquen exploración visual.

## 6. Hosting — recomendación

**VPS Hetzner CX22 (~4,6 €/mes, 2 vCPU/4GB, Falkenstein/Helsinki) + Docker
Compose + Tailscale.**

Razones frente a self-hosted en el Mac:
- Las alertas son sensibles al tiempo (los buenos pisos vuelan en horas);
  depender de que el Mac esté encendido rompe el caso de uso principal.
- El Lexar es un disco externo/extraíble: mala base para un Postgres 24/7
  (desmontajes). En el Lexar vive el **código**; los **datos** viven en el
  VPS.
- 4GB sobran para Postgres + 2 contenedores Python + FlareSolverr ocasional.

`houselocator-platform/scripts/deploy.sh`: rsync/git pull + `docker compose
up -d --build` por SSH. Sin CI/CD ni Kubernetes. Backup: `pg_dump` nocturno
en el VPS + descarga semanal al Lexar.

**Riesgo a vigilar**: IPs de datacenter tienen más papeletas de bloqueo en
Idealista que una IP residencial (mitigado por la escalera anti-bot del §3).
**Plan B ya soportado por el diseño**: si Idealista bloquea el VPS de forma
persistente, el job de Idealista se ejecuta *solo* en el Mac (launchd cada
45 min, escribe al Postgres del VPS vía Tailscale) — `ingest` es stateless y
la DB es el punto de encuentro, no requiere cambios de diseño.

## 7. Roadmap por fases

**Fase 0 — Cimientos**
1. Crear carpeta paraguas `houselocator/` + `git init` en
   `houselocator-platform`, `houselocator-ingest`, `houselocator-bot`.
   `houselocator-platform` incluye `compose.yaml`, migración inicial,
   `.env.example`, `scripts/bootstrap-workspace.sh`,
   `scripts/verify-local-stack.sh`, `docs/HLD.md` (este documento), y el
   `README.md` local de la carpeta paraguas (al estilo del de AeroRoute:
   nota de que no es parte de ningún repo publicado + enlaces).
2. Crear el bot con @BotFather; probar `sendMessage` a pelo.
3. (Opcional, al final de la fase 0) añadir entrada
   `wiki/projects/houselocator.md` en el repo `wiki-personal` como hub de
   contexto/decisiones, igual que existe para AeroRoute.

**Fase 1 — MVP: Fotocasa + alertas básicas**
4. `houselocator-ingest`: parser Fotocasa vía `__NEXT_DATA__` + test de
   contrato, pipeline de upsert + outbox, `new_scan` con APScheduler, scopes
   desde `search_filters`.
5. `houselocator-bot`: `/newfilter` (FSM), `/filters`, consumidor de
   outbox, alerta `new` con foto. Todo probado en local con compose.
6. Provisionar Hetzner + Tailscale + deploy. **Hito: alertas 24/7 de un
   portal.**

**Fase 1.1 — Histórico y robustez**
7. `full_sweep` diario, `price_history`, eventos `price_drop`/`delisted` (+
   alerta), `scrape_runs` + canary + alertas admin.

**Fase 1.2 — Idealista**
8. Parser Idealista (`curl_cffi`), rate limiting conservador, circuit
   breaker; FlareSolverr como sidecar solo si hace falta. Dedupe
   cross-portal ligero (mismo precio+m²+zona → `possible_duplicate` en
   `features`, sin bloquear alertas por ello en v1).

**Fase 1.3 — Tendencias**
9. Job `zone_daily_stats` + comandos `/trend`, `/stats`, `/history`,
   `/compare`.

**Fase 4 (opcional) — Dashboard**
10. `houselocator-web` con Streamlit, tras ≥3 meses de datos.

**Fase 2 — Hipotecas**: ver §8, solo diseño por ahora.

## 8. Fase 2 — `houselocator-mortgages` (solo diseño, sin código ahora)

- **Fuentes**: los bancos españoles no tienen APIs públicas de hipotecas;
  scraping de comparadores — HelpMyCash (tabla clara de fijas/variables/
  mixtas por banco), Kelisto e iAhorro como contraste, Idealista/Hipotecas.
  Euríbor diario desde fuente pública oficial (Banco de España/BCE).
- **Repo**: mismo patrón que `ingest` — Python, APScheduler (1 scrape/día
  basta), parsers por comparador con la misma interfaz `PortalScraper`,
  tests de contrato, canary.
- **Datos** (namespace `mtg_` en el mismo Postgres, migración añadida en
  `houselocator-platform`): `mtg_offers` (bank, type, tin, tae, plazo_max,
  ltv_max, bonificaciones jsonb, source, observed_at, content_hash),
  `mtg_offer_history`, `mtg_euribor_daily`. Reutiliza la outbox existente
  (o tabla gemela `mtg_events` — decisión trivial cuando llegue el momento).
- **Integración con el bot**: el bot ya se diseña con handlers modulares por
  dominio para esto. Futuro: `/mortgages [fija|variable]`, `/euribor`,
  `/simulate <precio> <ahorro> [años]`, y alerta "nueva hipoteca fija por
  debajo de X% TIN" como un tipo más de filtro (`search_filters.extra` ya lo
  permite).
- **Despliegue**: un contenedor más en el mismo compose del VPS. Nada del
  diseño de fase 1 necesita cambiar.

## 9. Consideraciones legales/éticas del scraping (pragmático)

- Uso estrictamente personal: no republicar, no revender, no exponer los
  datos públicamente (el dashboard, si llega, solo vía Tailscale).
- Volumen mínimo derivado de los filtros del usuario (pocas zonas), con
  rate limits de segundos → decenas/pocos cientos de requests/día por
  portal, carga irrelevante para ellos.
- Respetar `robots.txt` en lo razonable, sesiones y caché para no repetir
  peticiones, no scrapear áreas autenticadas ni datos personales más allá de
  lo que muestra el anuncio.
- Idealista prohíbe scraping en sus ToS: asumido con volumen ínfimo y sin
  redistribución; se solicitará su API oficial como complemento legítimo.
  Si un portal bloquea de forma persistente o pide cesar: se cesa.
- No se almacenan imágenes (solo URLs), para no redistribuir contenido con
  copyright.

## Ficheros críticos para arrancar la implementación

- `/Volumes/Lexar/Proyectos Personales/houselocator/README.md` (nota local, estilo AeroRoute)
- `/Volumes/Lexar/Proyectos Personales/houselocator/houselocator-platform/compose.yaml`
- `/Volumes/Lexar/Proyectos Personales/houselocator/houselocator-platform/db/migrations/001_initial_schema.sql`
- `/Volumes/Lexar/Proyectos Personales/houselocator/houselocator-platform/scripts/bootstrap-workspace.sh`
- `/Volumes/Lexar/Proyectos Personales/houselocator/houselocator-platform/scripts/verify-local-stack.sh`
- `/Volumes/Lexar/Proyectos Personales/houselocator/houselocator-platform/docs/HLD.md`
- `/Volumes/Lexar/Proyectos Personales/houselocator/houselocator-ingest/src/ingest/pipeline.py`
- `/Volumes/Lexar/Proyectos Personales/houselocator/houselocator-ingest/src/ingest/portals/fotocasa.py`
- `/Volumes/Lexar/Proyectos Personales/houselocator/houselocator-bot/src/bot/main.py`

## 10. Prompt para diseñar la UI con Claude (paso previo, opcional, antes de programar)

El usuario quiere generar primero un diseño visual/UX (dashboard web
`houselocator-web` + plantillas de mensajes del bot de Telegram) usando una
conversación de Claude dedicada a diseño, antes de escribir código. Esto es
independiente del orden de fases del roadmap (el dashboard se construye en
fase 4, pero el diseño se puede explorar ya). Prompt recomendado para pegar
en una conversación nueva de Claude:

```
Quiero diseñar la UI/UX de "HouseLocator", una app personal (un solo
usuario) para buscar piso en España. Aún no hay código de UI, es una hoja en
blanco. Dame un diseño visual completo (usa artifacts/HTML+CSS si puedes)
para estas pantallas:

1. Dashboard principal: resumen del día (nº de pisos nuevos, nº de bajadas
   de precio, mediana €/m² de las zonas seguidas y su variación), accesos
   rápidos a los filtros activos.
2. Listado de anuncios: tarjetas/tabla con foto, precio, €/m², m², hab.,
   zona, badges de estado ("NUEVO", "BAJADA -7%"), portal de origen
   (Idealista/Fotocasa), filtro por el que ha entrado, orden por fecha o
   precio.
3. Detalle de un anuncio: toda su info + gráfico de evolución de precio en
   el tiempo (puede tener 0, 1 o varios cambios de precio) + enlace al
   anuncio original.
4. Tendencias por zona: gráfico de mediana €/m² a lo largo del tiempo
   (rango seleccionable), comparativa entre 2-3 zonas, distribución de
   precios actual (p25/mediana/p75).
5. Gestión de filtros de búsqueda guardados: lista de filtros (ciudad,
   zonas, rango de precio, m² mín, habitaciones), alta/edición/pausa.
6. (Prepara hueco pero no lo desarrolles a fondo) una futura pestaña de
   "Hipotecas": comparativa de ofertas bancarias y un simulador de cuota.

Contexto técnico a tener en cuenta en el diseño: el backend es Postgres +
Python, el frontend probablemente Streamlit (limitado en personalización
CSS) — así que dame también qué es razonable conseguir con Streamlit puro
vs qué necesitaría CSS custom, para poder decidir. Se consulta sobre todo
desde el móvil (a través de Tailscale VPN, nunca expuesto a internet
público), así que el diseño debe funcionar bien en pantallas pequeñas.

Dame también, por separado, 2-3 plantillas de mensaje para las alertas del
bot de Telegram (que ya reciben foto + texto): una para "piso nuevo", una
para "bajada de precio", una para el resumen de tendencias (comando
/trend), cuidando que sean legibles en la notificación push del móvil sin
tener que abrir el chat.

Estilo: limpio, denso en datos pero legible, con soporte claro de modo
claro/oscuro. No hace falta branding corporativo, es una app personal.
```

Este prompt es autocontenido: no depende de que la otra conversación tenga
memoria de esta, así que se puede lanzar en paralelo o después, sin bloquear
el resto del roadmap.

## Verificación end-to-end (fase 1 MVP)

1. `docker compose up -d` desde `houselocator-platform` levanta Postgres +
   corre migraciones con dbmate sin error.
2. Insertar manualmente un `search_filter` de prueba (ciudad + zona amplia).
3. Ejecutar `ingest` una vez en modo manual (`python -m ingest.main
   --once`): comprobar que aparecen filas en `listings`, `listing_price_history`
   y `listing_events`, y una fila `ok` en `scrape_runs`.
4. Arrancar `bot`, confirmar que `/filters` devuelve el filtro creado.
5. Confirmar que llega un mensaje de Telegram real al chat del usuario para
   al menos un anuncio nuevo (`sendPhoto` con caption correcto).
6. Provocar un fallo simulado en el parser de Fotocasa (fixture vacía) y
   confirmar que el canary manda la alerta "posiblemente roto" al chat admin
   en vez de fallar en silencio.
7. `scripts/verify-local-stack.sh` en `houselocator-platform` automatiza los
   pasos 1–3 como smoke test repetible (mismo rol que en aeroroute-platform).
