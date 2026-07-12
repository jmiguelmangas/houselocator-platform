-- migrate:up
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
  price_m2          numeric GENERATED ALWAYS AS (price_eur::numeric / NULLIF(size_m2, 0)) STORED,
  rooms             smallint,
  bathrooms         smallint,
  floor             text,
  property_type     text,
  city              text NOT NULL,
  zone              text,
  address_raw       text,
  lat               double precision,
  lng               double precision,
  features          jsonb NOT NULL DEFAULT '{}',
  image_urls        jsonb NOT NULL DEFAULT '[]',
  description       text,
  content_hash      text NOT NULL,
  status            listing_status NOT NULL DEFAULT 'active',
  first_seen_at     timestamptz NOT NULL DEFAULT now(),
  last_seen_at      timestamptz NOT NULL DEFAULT now(),
  delisted_at       timestamptz,
  raw               jsonb,
  UNIQUE (portal, portal_listing_id)
);

CREATE INDEX listings_city_zone_status_idx ON listings (city, zone, status);
CREATE INDEX listings_status_last_seen_idx ON listings (status, last_seen_at);

CREATE TABLE listing_price_history (
  listing_id  bigint NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  price_eur   integer NOT NULL,
  observed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (listing_id, observed_at)
);

CREATE TABLE listing_events (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  listing_id bigint NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  event_type text NOT NULL CHECK (event_type IN ('new', 'price_drop', 'price_increase', 'delisted')),
  payload    jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX listing_events_created_at_idx ON listing_events (created_at);

CREATE TABLE scrape_runs (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  portal         portal NOT NULL,
  run_type       text NOT NULL CHECK (run_type IN ('new_scan', 'full_sweep')),
  started_at     timestamptz NOT NULL,
  finished_at    timestamptz,
  status         text NOT NULL CHECK (status IN ('ok', 'error', 'blocked', 'zero_results')),
  pages_fetched  integer,
  listings_found integer,
  new_count      integer,
  updated_count  integer,
  error          jsonb
);

CREATE INDEX scrape_runs_portal_started_idx ON scrape_runs (portal, started_at DESC);

CREATE TABLE zone_daily_stats (
  city             text NOT NULL,
  zone             text NOT NULL,
  day              date NOT NULL,
  median_price_m2  numeric,
  avg_price_m2     numeric,
  p25              numeric,
  p75              numeric,
  active_listings  integer,
  new_listings     integer,
  PRIMARY KEY (city, zone, day)
);

CREATE TABLE search_filters (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name                text NOT NULL,
  active              boolean NOT NULL DEFAULT true,
  city                text NOT NULL,
  zones               text[] NOT NULL DEFAULT '{}',
  price_min           integer,
  price_max           integer,
  size_min            integer,
  rooms_min           smallint,
  property_types      text[] NOT NULL DEFAULT '{}',
  extra               jsonb NOT NULL DEFAULT '{}',
  notify_price_drops  boolean NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE notifications (
  filter_id  bigint NOT NULL REFERENCES search_filters(id) ON DELETE CASCADE,
  listing_id bigint NOT NULL REFERENCES listings(id) ON DELETE CASCADE,
  event_type text NOT NULL,
  sent_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (filter_id, listing_id, event_type)
);

-- migrate:down
DROP TABLE IF EXISTS notifications;
DROP TABLE IF EXISTS search_filters;
DROP TABLE IF EXISTS zone_daily_stats;
DROP TABLE IF EXISTS scrape_runs;
DROP TABLE IF EXISTS listing_events;
DROP TABLE IF EXISTS listing_price_history;
DROP TABLE IF EXISTS listings;
DROP TYPE IF EXISTS listing_status;
DROP TYPE IF EXISTS portal;
