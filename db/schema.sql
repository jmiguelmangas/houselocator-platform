\restrict dbmate

-- Dumped from database version 16.14
-- Dumped by pg_dump version 18.4

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: listing_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.listing_status AS ENUM (
    'active',
    'delisted'
);


--
-- Name: portal; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.portal AS ENUM (
    'idealista',
    'fotocasa'
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: listing_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.listing_events (
    id bigint NOT NULL,
    listing_id bigint NOT NULL,
    event_type text NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT listing_events_event_type_check CHECK ((event_type = ANY (ARRAY['new'::text, 'price_drop'::text, 'price_increase'::text, 'delisted'::text])))
);


--
-- Name: listing_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.listing_events ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.listing_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: listing_price_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.listing_price_history (
    listing_id bigint NOT NULL,
    price_eur integer NOT NULL,
    observed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: listings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.listings (
    id bigint NOT NULL,
    portal public.portal NOT NULL,
    portal_listing_id text NOT NULL,
    url text NOT NULL,
    title text,
    price_eur integer NOT NULL,
    size_m2 integer,
    price_m2 numeric GENERATED ALWAYS AS (((price_eur)::numeric / (NULLIF(size_m2, 0))::numeric)) STORED,
    rooms smallint,
    bathrooms smallint,
    floor text,
    property_type text,
    city text NOT NULL,
    zone text,
    address_raw text,
    lat double precision,
    lng double precision,
    features jsonb DEFAULT '{}'::jsonb NOT NULL,
    image_urls jsonb DEFAULT '[]'::jsonb NOT NULL,
    description text,
    content_hash text NOT NULL,
    status public.listing_status DEFAULT 'active'::public.listing_status NOT NULL,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    delisted_at timestamp with time zone,
    raw jsonb
);


--
-- Name: listings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.listings ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.listings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    filter_id bigint NOT NULL,
    listing_id bigint NOT NULL,
    event_type text NOT NULL,
    sent_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: scrape_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scrape_runs (
    id bigint NOT NULL,
    portal public.portal NOT NULL,
    run_type text NOT NULL,
    started_at timestamp with time zone NOT NULL,
    finished_at timestamp with time zone,
    status text NOT NULL,
    pages_fetched integer,
    listings_found integer,
    new_count integer,
    updated_count integer,
    error jsonb,
    CONSTRAINT scrape_runs_run_type_check CHECK ((run_type = ANY (ARRAY['new_scan'::text, 'full_sweep'::text]))),
    CONSTRAINT scrape_runs_status_check CHECK ((status = ANY (ARRAY['ok'::text, 'error'::text, 'blocked'::text, 'zero_results'::text])))
);


--
-- Name: scrape_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.scrape_runs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.scrape_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: search_filters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_filters (
    id bigint NOT NULL,
    name text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    city text NOT NULL,
    zones text[] DEFAULT '{}'::text[] NOT NULL,
    price_min integer,
    price_max integer,
    size_min integer,
    rooms_min smallint,
    property_types text[] DEFAULT '{}'::text[] NOT NULL,
    extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    notify_price_drops boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: search_filters_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.search_filters ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.search_filters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: zone_daily_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.zone_daily_stats (
    city text NOT NULL,
    zone text NOT NULL,
    day date NOT NULL,
    median_price_m2 numeric,
    avg_price_m2 numeric,
    p25 numeric,
    p75 numeric,
    active_listings integer,
    new_listings integer
);


--
-- Name: listing_events listing_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.listing_events
    ADD CONSTRAINT listing_events_pkey PRIMARY KEY (id);


--
-- Name: listing_price_history listing_price_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.listing_price_history
    ADD CONSTRAINT listing_price_history_pkey PRIMARY KEY (listing_id, observed_at);


--
-- Name: listings listings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.listings
    ADD CONSTRAINT listings_pkey PRIMARY KEY (id);


--
-- Name: listings listings_portal_portal_listing_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.listings
    ADD CONSTRAINT listings_portal_portal_listing_id_key UNIQUE (portal, portal_listing_id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (filter_id, listing_id, event_type);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: scrape_runs scrape_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.scrape_runs
    ADD CONSTRAINT scrape_runs_pkey PRIMARY KEY (id);


--
-- Name: search_filters search_filters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_filters
    ADD CONSTRAINT search_filters_pkey PRIMARY KEY (id);


--
-- Name: zone_daily_stats zone_daily_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.zone_daily_stats
    ADD CONSTRAINT zone_daily_stats_pkey PRIMARY KEY (city, zone, day);


--
-- Name: listing_events_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX listing_events_created_at_idx ON public.listing_events USING btree (created_at);


--
-- Name: listings_city_zone_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX listings_city_zone_status_idx ON public.listings USING btree (city, zone, status);


--
-- Name: listings_status_last_seen_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX listings_status_last_seen_idx ON public.listings USING btree (status, last_seen_at);


--
-- Name: scrape_runs_portal_started_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX scrape_runs_portal_started_idx ON public.scrape_runs USING btree (portal, started_at DESC);


--
-- Name: listing_events listing_events_listing_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.listing_events
    ADD CONSTRAINT listing_events_listing_id_fkey FOREIGN KEY (listing_id) REFERENCES public.listings(id) ON DELETE CASCADE;


--
-- Name: listing_price_history listing_price_history_listing_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.listing_price_history
    ADD CONSTRAINT listing_price_history_listing_id_fkey FOREIGN KEY (listing_id) REFERENCES public.listings(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_filter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_filter_id_fkey FOREIGN KEY (filter_id) REFERENCES public.search_filters(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_listing_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_listing_id_fkey FOREIGN KEY (listing_id) REFERENCES public.listings(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict dbmate


--
-- Dbmate schema migrations
--

INSERT INTO public.schema_migrations (version) VALUES
    ('20260712000001');
